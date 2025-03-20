/*
 * ipsw.c
 * Utilities for extracting and manipulating IPSWs
 *
 * Copyright (c) 2012-2019 Nikias Bassen. All Rights Reserved.
 * Copyright (c) 2010-2012 Martin Szulecki. All Rights Reserved.
 * Copyright (c) 2010 Joshua Hill. All Rights Reserved.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 */

#ifdef HAVE_CONFIG_H
#include <config.h>
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <dirent.h>
#include <zip.h>

#include <libimobiledevice-glue/sha.h>
#include <libimobiledevice-glue/termcolors.h>
#include <plist/plist.h>

#include "ipsw.h"
#include "locking.h"
#include "download.h"
#include "common.h"
#include "idevicerestore.h"

#define BUFSIZE 0x100000

static int cancel_flag = 0;

// 内部辅助函数，用于构建完整路径
static char* build_path(const char* path, const char* file)
{
	size_t plen = strlen(path);
	size_t flen = strlen(file);
	char *fullpath = malloc(plen + flen + 2);
	if (!fullpath) {
		return NULL;
	}
	memcpy(fullpath, path, plen);
	fullpath[plen] = '/';
	memcpy(fullpath+plen+1, file, flen);
	fullpath[plen+1+flen] = '\0';
	return fullpath;
}


// 新增：内部辅助函数，用于获取解密密钥
static const char* get_decryption_key(ipsw_archive_t ipsw) {
    if (!ipsw || !ipsw->key_callback) {
        return NULL;
    }
    return ipsw->key_callback(ipsw->key_user_data);
}

// 新增：带回调的打开函数实现
ipsw_archive_t ipsw_open_with_callback(const char* ipsw, decrypt_key_callback_t callback, void* user_data)
{
    if (!ipsw) {
        error("ERROR: Invalid IPSW path\n");
        return NULL;
    }

    int err = 0;
    ipsw_archive_t archive = (ipsw_archive_t)calloc(1, sizeof(struct ipsw_archive));
    if (!archive) {
        error("ERROR: Out of memory\n");
        return NULL;
    }

    struct stat fst;
    if (stat(ipsw, &fst) != 0) {
        error("ERROR: ipsw_open_with_callback %s: %s\n", ipsw, strerror(errno));
        free(archive);
        return NULL;
    }

    if (S_ISDIR(fst.st_mode)) {
        archive->zip = 0;
        archive->key_callback = NULL;
        archive->key_user_data = NULL;
    } else {
        struct zip *zip = zip_open(ipsw, 0, &err);
        if (!zip) {
            error("ERROR: zip_open: %s: %d\n", ipsw, err);
            free(archive);
            return NULL;
        }
        archive->zip = 1;
        archive->key_callback = callback;
        archive->key_user_data = user_data;
    }

    archive->path = strdup(ipsw);
    return archive;
}


int ipsw_print_info(const char* path)
{
	struct stat fst;

	if (stat(path, &fst) != 0) {
		error("ERROR: '%s': %s\n", path, strerror(errno));
		return -1;
	}

	char thepath[PATH_MAX];

	if (S_ISDIR(fst.st_mode)) {
		snprintf(thepath, sizeof(thepath), "%s/BuildManifest.plist", path);
		if (stat(thepath, &fst) != 0) {
			error("ERROR: '%s': %s\n", thepath, strerror(errno));
			return -1;
		}
	} else {
		snprintf(thepath, sizeof(thepath), "%s", path);
	}

	FILE* f = fopen(thepath, "r");
	if (!f) {
		error("ERROR: Can't open '%s': %s\n", thepath, strerror(errno));
		return -1;
	}
	uint32_t magic;
	if (fread(&magic, 1, 4, f) != 4) {
		fclose(f);
		fprintf(stderr, "Failed to read from '%s'\n", path);
		return -1;
	}
	fclose(f);

	char* plist_buf = NULL;
	uint32_t plist_len = 0;

	if (memcmp(&magic, "PK\x03\x04", 4) == 0) {
		ipsw_archive_t ipsw = ipsw_open(thepath);
		unsigned int rlen = 0;
		if (ipsw_extract_to_memory(ipsw, "BuildManifest.plist", (unsigned char**)&plist_buf, &rlen) < 0) {
			ipsw_close(ipsw);
			error("ERROR: Failed to extract BuildManifest.plist from IPSW!\n");
			return -1;
		}
		ipsw_close(ipsw);
		plist_len = (uint32_t)rlen;
	} else {
		size_t rlen = 0;
		if (read_file(thepath, (void**)&plist_buf, &rlen) < 0) {
			error("ERROR: Failed to read BuildManifest.plist!\n");
			return -1;
		}
		plist_len = (uint32_t)rlen;
	}

	plist_t manifest = NULL;
	plist_from_memory(plist_buf, plist_len, &manifest, NULL);
	free(plist_buf);

	plist_t val;

	char* prod_ver = NULL;
	char* build_ver = NULL;

	val = plist_dict_get_item(manifest, "ProductVersion");
	if (val) {
		plist_get_string_val(val, &prod_ver);
	}

	val = plist_dict_get_item(manifest, "ProductBuildVersion");
	if (val) {
		plist_get_string_val(val, &build_ver);
	}

	cprintf(FG_WHITE "Product Version: " FG_BRIGHT_YELLOW "%s" COLOR_RESET FG_WHITE "   Build: " FG_BRIGHT_YELLOW "%s" COLOR_RESET "\n", prod_ver, build_ver);
	free(prod_ver);
	free(build_ver);
	cprintf(FG_WHITE "Supported Product Types:" COLOR_RESET);
	val = plist_dict_get_item(manifest, "SupportedProductTypes");
	if (val) {
		plist_array_iter iter = NULL;
		plist_array_new_iter(val, &iter);
		if (iter) {
			plist_t item = NULL;
			do {
				plist_array_next_item(val, iter, &item);
				if (item) {
					char* item_str = NULL;
					plist_get_string_val(item, &item_str);
					cprintf(" " FG_BRIGHT_CYAN "%s" COLOR_RESET, item_str);
					free(item_str);
				}
			} while (item);
			free(iter);
		}
	}
	cprintf("\n");

	cprintf(FG_WHITE "Build Identities:" COLOR_RESET "\n");

	plist_t build_ids_grouped = plist_new_dict();

	plist_t build_ids = plist_dict_get_item(manifest, "BuildIdentities");
	plist_array_iter build_id_iter = NULL;
	plist_array_new_iter(build_ids, &build_id_iter);
	if (build_id_iter) {
		plist_t build_identity = NULL;
		do {
			plist_array_next_item(build_ids, build_id_iter, &build_identity);
			if (!build_identity) {
				break;
			}
			plist_t node;
			char* variant_str = NULL;

			node = plist_access_path(build_identity, 2, "Info", "Variant");
			plist_get_string_val(node, &variant_str);

			plist_t entries = NULL;
			plist_t group = plist_dict_get_item(build_ids_grouped, variant_str);
			if (!group) {
				group = plist_new_dict();
				node = plist_access_path(build_identity, 2, "Info", "RestoreBehavior");
				if (node) {
					plist_dict_set_item(group, "RestoreBehavior", plist_copy(node));
				} else {
					if (strstr(variant_str, "Upgrade")) {
						plist_dict_set_item(group, "RestoreBehavior", plist_new_string("Update"));
					} else if (strstr(variant_str, "Erase")) {
						plist_dict_set_item(group, "RestoreBehavior", plist_new_string("Erase"));
					}
				}
				entries = plist_new_array();
				plist_dict_set_item(group, "Entries", entries);
				plist_dict_set_item(build_ids_grouped, variant_str, group);
			} else {
				entries = plist_dict_get_item(group, "Entries");
			}
			free(variant_str);
			plist_array_append_item(entries, plist_copy(build_identity));
		} while (build_identity);
		free(build_id_iter);
	}

	plist_dict_iter build_ids_group_iter = NULL;
	plist_dict_new_iter(build_ids_grouped, &build_ids_group_iter);
	if (build_ids_group_iter) {
		plist_t group = NULL;
		int group_no = 0;
		do {
			group = NULL;
			char* key = NULL;
			plist_dict_next_item(build_ids_grouped, build_ids_group_iter, &key, &group);
			if (!key) {
				break;
			}
			plist_t node;
			char* rbehavior = NULL;

			group_no++;
			node = plist_dict_get_item(group, "RestoreBehavior");
			plist_get_string_val(node, &rbehavior);
			cprintf("  " FG_WHITE "[%d] Variant: " FG_BRIGHT_CYAN "%s" FG_WHITE "   Behavior: " FG_BRIGHT_CYAN "%s" COLOR_RESET "\n", group_no, key, rbehavior);
			free(key);
			free(rbehavior);

			build_ids = plist_dict_get_item(group, "Entries");
			if (!build_ids) {
				continue;
			}
			build_id_iter = NULL;
			plist_array_new_iter(build_ids, &build_id_iter);
			if (!build_id_iter) {
				continue;
			}
			plist_t build_id;
			do {
				build_id = NULL;
				plist_array_next_item(build_ids, build_id_iter, &build_id);
				if (!build_id) {
					break;
				}
				uint64_t chip_id = 0;
				uint64_t board_id = 0;
				char* hwmodel = NULL;

				node = plist_dict_get_item(build_id, "ApChipID");
				if (PLIST_IS_STRING(node)) {
					char* strval = NULL;
					plist_get_string_val(node, &strval);
					if (strval) {
						chip_id = strtoull(strval, NULL, 0);
						free(strval);
					}
				} else {
					plist_get_uint_val(node, &chip_id);
				}

				node = plist_dict_get_item(build_id, "ApBoardID");
				if (PLIST_IS_STRING(node)) {
					char* strval = NULL;
					plist_get_string_val(node, &strval);
					if (strval) {
						board_id = strtoull(strval, NULL, 0);
						free(strval);
					}
				} else {
					plist_get_uint_val(node, &board_id);
				}

				node = plist_access_path(build_id, 2, "Info", "DeviceClass");
				plist_get_string_val(node, &hwmodel);

				irecv_device_t irecvdev = NULL;
				if (irecv_devices_get_device_by_hardware_model(hwmodel, &irecvdev) == 0) {
					cprintf("    ChipID: " FG_GREEN "%04x" COLOR_RESET "   BoardID: " FG_GREEN "%02x" COLOR_RESET "   Model: " FG_YELLOW "%-8s" COLOR_RESET "  " FG_MAGENTA "%s" COLOR_RESET "\n", (int)chip_id, (int)board_id, hwmodel, irecvdev->display_name);
				} else {
					cprintf("    ChipID: " FG_GREEN "%04x" COLOR_RESET "   BoardID: " FG_GREEN "%02x" COLOR_RESET "   Model: " FG_YELLOW "%s" COLOR_RESET "\n", (int)chip_id, (int)board_id, hwmodel);
				}
				free(hwmodel);
			} while (build_id);
			free(build_id_iter);
		} while (group);
		free(build_ids_group_iter);
	}
	plist_free(build_ids_grouped);

	plist_free(manifest);

	return 0;
}

// 实现标准打开函数
ipsw_archive_t ipsw_open(const char* ipsw)
{
    return ipsw_open_with_callback(ipsw, NULL, NULL);
}


void ipsw_close(ipsw_archive_t ipsw)
{
	if (ipsw != NULL) {
		free(ipsw->path);
		free(ipsw);
	}
}

int ipsw_is_directory(const char* ipsw)
{
	struct stat fst;
	memset(&fst, '\0', sizeof(fst));
	if (stat(ipsw, &fst) != 0) {
		return 0;
	}
	return S_ISDIR(fst.st_mode);
}

int ipsw_get_file_size(ipsw_archive_t ipsw, const char* infile, uint64_t* size)
{
    if (!ipsw || !infile || !size) {
        return IPSW_E_INVALID_ARG;
    }

    if (ipsw->zip) {
        int err = 0;
        struct zip *zip = zip_open(ipsw->path, 0, &err);
        if (!zip) {
            return IPSW_E_IO_ERROR;
        }

        int zindex = zip_name_locate(zip, infile, 0);
        if (zindex < 0) {
            zip_unchange_all(zip);
            zip_close(zip);
            return IPSW_E_NOT_FOUND;
        }

        struct zip_stat zstat;
        zip_stat_init(&zstat);
        if (zip_stat_index(zip, zindex, 0, &zstat) != 0) {
            zip_unchange_all(zip);
            zip_close(zip);
            return IPSW_E_CORRUPT;
        }

        *size = zstat.size;
        zip_unchange_all(zip);
        zip_close(zip);
        return IPSW_E_SUCCESS;
    } else {
        char *filepath = build_path(ipsw->path, infile);
        if (!filepath) {
            return IPSW_E_NO_MEMORY;
        }

        struct stat fst;
        if (stat(filepath, &fst) != 0) {
            free(filepath);
            return IPSW_E_NOT_FOUND;
        }

        *size = fst.st_size;
        free(filepath);
        return IPSW_E_SUCCESS;
    }
}


int ipsw_extract_to_file_with_progress(ipsw_archive_t ipsw, const char* infile, const char* outfile, int print_progress)
{
    if (!ipsw || !infile || !outfile) {
        return IPSW_E_INVALID_ARG;
    }

    cancel_flag = 0;

    if (ipsw->zip) {
        int err = 0;
        struct zip *zip = zip_open(ipsw->path, 0, &err);
        if (!zip) {
            return IPSW_E_IO_ERROR;
        }

        int zindex = zip_name_locate(zip, infile, 0);
        if (zindex < 0) {
            zip_close(zip);
            return IPSW_E_NOT_FOUND;
        }

        struct zip_stat zstat;
        zip_stat_init(&zstat);
        if (zip_stat_index(zip, zindex, 0, &zstat) != 0) {
            zip_close(zip);
            return IPSW_E_CORRUPT;
        }

        // 获取密钥并尝试打开加密文件
        const char* key = get_decryption_key(ipsw);
        struct zip_file* zfile;
        if (key) {
            zfile = zip_fopen_index_encrypted(zip, zindex, ZIP_FL_ENC_GUESS, key);
        } else {
            zfile = zip_fopen_index(zip, zindex, 0);
        }

        if (!zfile) {
            zip_error_t *error = zip_get_error(zip);
            #ifdef ZIP_ER_ENCRYPTED
            // 如果定义了 ZIP_ER_ENCRYPTED，使用它
            if (error->zip_err == ZIP_ER_ENCRYPTED) {
                zip_close(zip);
                return IPSW_E_ENCRYPTED;
            }
            #endif
            if (error->zip_err == ZIP_ER_WRONGPASSWD) {
                zip_close(zip);
                return IPSW_E_WRONG_PASSWORD;
            }
            // 对于其他版本的 libzip，通过检查加密标志来判断
            struct zip_stat zstat_check;
            zip_stat_init(&zstat_check);
            if (zip_stat_index(zip, zindex, 0, &zstat_check) == 0) {
                if (zstat_check.encryption_method != 0) {
                    zip_close(zip);
                    return IPSW_E_ENCRYPTED;
                }
            }
            zip_close(zip);
            return IPSW_E_IO_ERROR;
        }

        FILE* fd = fopen(outfile, "wb");
        if (!fd) {
            zip_fclose(zfile);
            zip_close(zip);
            return IPSW_E_IO_ERROR;
        }

        char* buffer = (char*)malloc(BUFSIZE);
        if (!buffer) {
            fclose(fd);
            zip_fclose(zfile);
            zip_close(zip);
            return IPSW_E_NO_MEMORY;
        }

        uint64_t bytes = 0;
        int ret = IPSW_E_SUCCESS;

        while (bytes < zstat.size) {
            if (cancel_flag) {
                ret = IPSW_E_CANCELED;
                break;
            }

            size_t to_read = ((zstat.size - bytes) < BUFSIZE) ? 
                            (zstat.size - bytes) : BUFSIZE;

            zip_int64_t count = zip_fread(zfile, buffer, to_read);
            if (count < 0) {
                ret = IPSW_E_IO_ERROR;
                break;
            }

            if (fwrite(buffer, 1, count, fd) != count) {
                ret = IPSW_E_IO_ERROR;
                break;
            }

            bytes += count;
            if (print_progress) {
                print_progress_bar(((double)bytes / (double)zstat.size) * 100.0);
            }
        }

        free(buffer);
        fclose(fd);
        zip_fclose(zfile);
        zip_close(zip);

        return ret;
    } else {
        // 处理目录格式的IPSW
        char *filepath = build_path(ipsw->path, infile);
        if (!filepath) {
            return IPSW_E_NO_MEMORY;
        }

        FILE *fi = fopen(filepath, "rb");
        if (!fi) {
            free(filepath);
            return IPSW_E_IO_ERROR;
        }

        struct stat fst;
        if (fstat(fileno(fi), &fst) != 0) {
            fclose(fi);
            free(filepath);
            return IPSW_E_IO_ERROR;
        }

        FILE *fo = fopen(outfile, "wb");
        if (!fo) {
            fclose(fi);
            free(filepath);
            return IPSW_E_IO_ERROR;
        }

        char* buffer = (char*)malloc(BUFSIZE);
        if (!buffer) {
            fclose(fo);
            fclose(fi);
            free(filepath);
            return IPSW_E_NO_MEMORY;
        }

        int ret = IPSW_E_SUCCESS;
        uint64_t bytes = 0;

        while (!feof(fi)) {
            if (cancel_flag) {
                ret = IPSW_E_CANCELED;
                break;
            }

            size_t count = fread(buffer, 1, BUFSIZE, fi);
            if (ferror(fi)) {
                ret = IPSW_E_IO_ERROR;
                break;
            }

            if (count > 0) {
                if (fwrite(buffer, 1, count, fo) != count) {
                    ret = IPSW_E_IO_ERROR;
                    break;
                }
                bytes += count;

                if (print_progress) {
                    print_progress_bar(((double)bytes / (double)fst.st_size) * 100.0);
                }
            }
        }

        free(buffer);
        fclose(fo);
        fclose(fi);
        free(filepath);

        return ret;
    }
}

int ipsw_extract_to_file(ipsw_archive_t ipsw, const char* infile, const char* outfile)
{
	return ipsw_extract_to_file_with_progress(ipsw, infile, outfile, 0);
}


int ipsw_file_exists(ipsw_archive_t ipsw, const char* infile)
{
    if (!ipsw || !infile) {
        return 0;
    }

    if (ipsw->zip) {
        int err = 0;
        struct zip *zip = zip_open(ipsw->path, 0, &err);
        if (!zip) {
            return 0;
        }

        int zindex = zip_name_locate(zip, infile, 0);
        zip_unchange_all(zip);
        zip_close(zip);

        return (zindex >= 0) ? 1 : 0;
    } else {
        char *filepath = build_path(ipsw->path, infile);
        if (!filepath) {
            return 0;
        }

        int exists = (access(filepath, R_OK) == 0);
        free(filepath);
        return exists;
    }
}


int ipsw_extract_to_memory(ipsw_archive_t ipsw, const char* infile, unsigned char** pbuffer, unsigned int* psize)
{
    size_t size = 0;
    unsigned char* buffer = NULL;

    if (ipsw == NULL) {
        fprintf(stderr, "ERROR: Invalid archive\n");
        return -1;
    }

    if (ipsw->zip) {
        int err = 0;
        struct zip *zip = zip_open(ipsw->path, 0, &err);
        if (zip == NULL) {
            fprintf(stderr, "ERROR: zip_open failed for %s: %d\n", ipsw->path, err);
            return -1;
        }

        int zindex = zip_name_locate(zip, infile, 0);
        if (zindex < 0) {
            zip_close(zip);
            fprintf(stderr, "ERROR: File '%s' not found in archive.\n", infile);
            return -1;
        }

        struct zip_stat zstat;
        zip_stat_init(&zstat);
        if (zip_stat_index(zip, zindex, 0, &zstat) != 0) {
            zip_close(zip);
            fprintf(stderr, "ERROR: zip_stat_index failed for %s\n", infile);
            return -1;
        }

        // **检查文件是否加密**
        if (zstat.encryption_method != 0) {
            const char* key = get_decryption_key(ipsw);
            if (!key) {
                fprintf(stderr, "ERROR: File '%s' is encrypted, but no decryption key provided!\n", infile);
                zip_close(zip);
                return IPSW_E_ENCRYPTED;
            }
            if (zip_set_default_password(zip, key) != 0) {
                fprintf(stderr, "ERROR: Failed to set ZIP decryption password\n");
                zip_close(zip);
                return -1;
            }
        }

        struct zip_file* zfile = zip_fopen_index(zip, zindex, 0);
        if (zfile == NULL) {
            zip_close(zip);
            fprintf(stderr, "ERROR: zip_fopen_index failed for %s (wrong password?)\n", infile);
            return -1;
        }

        size = zstat.size;
        buffer = (unsigned char*) malloc(size+1);
        if (buffer == NULL) {
            fprintf(stderr, "ERROR: Out of memory\n");
            zip_fclose(zfile);
            zip_close(zip);
            return -1;
        }

        zip_int64_t zr = zip_fread(zfile, buffer, size);
        zip_fclose(zfile);
        zip_close(zip);

        if (zr < 0) {
            fprintf(stderr, "ERROR: zip_fread failed for %s\n", infile);
            free(buffer);
            return -1;
        } else if (zr != size) {
            fprintf(stderr, "ERROR: zip_fread: '%s' got only %lld of %zu bytes\n", infile, zr, size);
            free(buffer);
            return -1;
        }

        buffer[size] = '\0';
    } else {
        char *filepath = build_path(ipsw->path, infile);
        struct stat fst;
#ifdef WIN32
        if (stat(filepath, &fst) != 0) {
#else
        if (lstat(filepath, &fst) != 0) {
#endif
            fprintf(stderr, "ERROR: %s: stat failed for %s: %s\n", __func__, filepath, strerror(errno));
            free(filepath);
            return -1;
        }
        size = fst.st_size;
        buffer = (unsigned char*)malloc(size+1);
        if (buffer == NULL) {
            fprintf(stderr, "ERROR: Out of memory\n");
            free(filepath);
            return -1;
        }

#ifndef WIN32
        if (S_ISLNK(fst.st_mode)) {
            if (readlink(filepath, (char*)buffer, size) < 0) {
                fprintf(stderr, "ERROR: %s: readlink failed for %s: %s\n", __func__, filepath, strerror(errno));
                free(filepath);
                free(buffer);
                return -1;
            }
        } else {
#endif
            FILE *f = fopen(filepath, "rb");
            if (!f) {
                fprintf(stderr, "ERROR: %s: fopen failed for %s: %s\n", __func__, filepath, strerror(errno));
                free(filepath);
                free(buffer);
                return -2;
            }
            if (fread(buffer, 1, size, f) != size) {
                fclose(f);
                fprintf(stderr, "ERROR: %s: fread failed for %s: %s\n", __func__, filepath, strerror(errno));
                free(filepath);
                free(buffer);
                return -1;
            }
            fclose(f);
#ifndef WIN32
        }
#endif
        buffer[size] = '\0';

        free(filepath);
    }

    *pbuffer = buffer;
    *psize = size;
    return 0;
}


int ipsw_extract_send(ipsw_archive_t ipsw, const char* infile, int blocksize, ipsw_send_cb send_callback, void* ctx)
{
    if (!ipsw || !infile || !send_callback) {
        return IPSW_E_INVALID_ARG;
    }

    if (blocksize <= 0) {
        blocksize = BUFSIZE;
    }

    unsigned char* buffer = NULL;
    size_t done = 0;
    size_t total_size = 0;

    if (ipsw->zip) {
        int err = 0;
        struct zip *zip = zip_open(ipsw->path, 0, &err);
        if (!zip) {
            return IPSW_E_IO_ERROR;
        }

        int zindex = zip_name_locate(zip, infile, 0);
        if (zindex < 0) {
            zip_close(zip);
            return IPSW_E_NOT_FOUND;
        }

        struct zip_stat zstat;
        zip_stat_init(&zstat);
        if (zip_stat_index(zip, zindex, 0, &zstat) != 0) {
            zip_close(zip);
            return IPSW_E_CORRUPT;
        }

        // 检查文件是否加密
        if (zstat.encryption_method != 0) {
            const char* key = get_decryption_key(ipsw);
            if (!key) {
                zip_close(zip);
                return IPSW_E_ENCRYPTED;
            }
        }

        // 获取密钥并尝试打开加密文件
        const char* key = get_decryption_key(ipsw);
        struct zip_file* zfile;
        if (key) {
            zfile = zip_fopen_index_encrypted(zip, zindex, ZIP_FL_ENC_GUESS, key);
        } else {
            zfile = zip_fopen_index(zip, zindex, 0);
        }

        if (!zfile) {
            zip_error_t *error = zip_get_error(zip);
            if (error->zip_err == ZIP_ER_WRONGPASSWD) {
                zip_close(zip);
                return IPSW_E_WRONG_PASSWORD;
            }
            // 如果文件是加密的但没有提供密钥
            if (zstat.encryption_method != 0) {
                zip_close(zip);
                return IPSW_E_ENCRYPTED;
            }
            zip_close(zip);
            return IPSW_E_IO_ERROR;
        }

        total_size = zstat.size;
        buffer = (unsigned char*)malloc(blocksize);
        if (!buffer) {
            zip_fclose(zfile);
            zip_close(zip);
            return IPSW_E_NO_MEMORY;
        }

        while (done < total_size) {
            if (cancel_flag) {
                free(buffer);
                zip_fclose(zfile);
                zip_close(zip);
                return IPSW_E_CANCELED;
            }

            size_t size = total_size - done;
            if (size > blocksize) {
                size = blocksize;
            }

            zip_int64_t zr = zip_fread(zfile, buffer, size);
            if (zr < 0) {
                free(buffer);
                zip_fclose(zfile);
                zip_close(zip);
                return IPSW_E_IO_ERROR;
            } else if (zr == 0) {
                break;  // EOF
            }

            if (send_callback(ctx, buffer, zr, done, total_size) < 0) {
                free(buffer);
                zip_fclose(zfile);
                zip_close(zip);
                return IPSW_E_IO_ERROR;
            }
            done += zr;
        }

        free(buffer);
        zip_fclose(zfile);
        zip_close(zip);
    } else {
        char *filepath = build_path(ipsw->path, infile);
        if (!filepath) {
            return IPSW_E_NO_MEMORY;
        }

        struct stat fst;
#ifdef WIN32
        if (stat(filepath, &fst) != 0) {
#else
        if (lstat(filepath, &fst) != 0) {
#endif
            free(filepath);
            return IPSW_E_NOT_FOUND;
        }

        total_size = fst.st_size;
        buffer = (unsigned char*)malloc(blocksize);
        if (!buffer) {
            free(filepath);
            return IPSW_E_NO_MEMORY;
        }

#ifndef WIN32
        if (S_ISLNK(fst.st_mode)) {
            ssize_t rl = readlink(filepath, (char*)buffer, 
                                (total_size > blocksize) ? blocksize : total_size);
            if (rl < 0) {
                free(buffer);
                free(filepath);
                return IPSW_E_IO_ERROR;
            }
            if (send_callback(ctx, buffer, (size_t)rl, 0, 0) < 0) {
                free(buffer);
                free(filepath);
                return IPSW_E_IO_ERROR;
            }
        } else {
#endif
            FILE *f = fopen(filepath, "rb");
            if (!f) {
                free(buffer);
                free(filepath);
                return IPSW_E_IO_ERROR;
            }

            while (done < total_size) {
                if (cancel_flag) {
                    fclose(f);
                    free(buffer);
                    free(filepath);
                    return IPSW_E_CANCELED;
                }

                size_t size = total_size - done;
                if (size > blocksize) {
                    size = blocksize;
                }

                size_t fr = fread(buffer, 1, size, f);
                if (fr != size) {
                    fclose(f);
                    free(buffer);
                    free(filepath);
                    return IPSW_E_IO_ERROR;
                }

                if (send_callback(ctx, buffer, fr, done, total_size) < 0) {
                    fclose(f);
                    free(buffer);
                    free(filepath);
                    return IPSW_E_IO_ERROR;
                }
                done += fr;
            }
            fclose(f);
#ifndef WIN32
        }
#endif
        free(filepath);
        free(buffer);
    }

    if (done < total_size) {
        error("ERROR: %s: Sending file data for %s failed (sent %" PRIu64 "/%" PRIu64 ")\n",
              __func__, infile, (uint64_t)done, (uint64_t)total_size);
        return IPSW_E_IO_ERROR;
    }

    // 发送 NULL buffer 标记传输结束
    send_callback(ctx, NULL, 0, done, total_size);
    return IPSW_E_SUCCESS;
}


// BuildManifest 提取实现
int ipsw_extract_build_manifest(ipsw_archive_t ipsw, plist_t* buildmanifest, int *tss_enabled)
{
    if (!ipsw || !buildmanifest || !tss_enabled) {
        return IPSW_E_INVALID_ARG;
    }

    unsigned int size = 0;
    unsigned char* data = NULL;
    int ret;

    *tss_enabled = 0;
    *buildmanifest = NULL;

    debug("📁 开始提取 BuildManifesto.plist 或 BuildManifest.plist");

    // 先尝试旧版本的 BuildManifesto.plist
    if (ipsw_file_exists(ipsw, "BuildManifesto.plist")) {
        ret = ipsw_extract_to_memory(ipsw, "BuildManifesto.plist", &data, &size);
        if (ret == IPSW_E_SUCCESS) {
            debug("✅ 成功提取 BuildManifesto.plist");
            plist_from_xml((char*)data, size, buildmanifest);
            free(data);
            if (!*buildmanifest) {
                debug("❌ plist 解析失败");
                return IPSW_E_INVALID_PLIST;
            }
            return IPSW_E_SUCCESS;
        } else if (ret == IPSW_E_ENCRYPTED && ipsw->key_callback) {
            debug("🔑 发现加密的 BuildManifesto.plist，尝试获取解密密钥");
            const char* key = ipsw->key_callback(ipsw->key_user_data);
            if (key) {
                debug("✅ 成功获取解密密钥: %s", key);
                ret = ipsw_extract_to_memory(ipsw, "BuildManifesto.plist", &data, &size);
                if (ret == IPSW_E_SUCCESS) {
                    plist_from_xml((char*)data, size, buildmanifest);
                    free(data);
                    if (!*buildmanifest) {
                        debug("❌ plist 解析失败");
                        return IPSW_E_INVALID_PLIST;
                    }
                    return IPSW_E_SUCCESS;
                }
            } else {
                debug("❌ 无法获取解密密钥");
            }
        }
    }

    // 尝试新版本的 BuildManifest.plist
    debug("📁 尝试提取 BuildManifest.plist");
    ret = ipsw_extract_to_memory(ipsw, "BuildManifest.plist", &data, &size);
    if (ret == IPSW_E_SUCCESS) {
        debug("✅ 成功提取 BuildManifest.plist");
        *tss_enabled = 1;
        plist_from_xml((char*)data, size, buildmanifest);
        free(data);
        if (!*buildmanifest) {
            debug("❌ plist 解析失败");
            return IPSW_E_INVALID_PLIST;
        }
        return IPSW_E_SUCCESS;
    }

    debug("❌ 无法提取任何 BuildManifest 文件，错误代码: %d", ret);
    return ret;
}


// Restore.plist 提取实现
int ipsw_extract_restore_plist(ipsw_archive_t ipsw, plist_t* restore_plist)
{
    if (!ipsw || !restore_plist) {
        return IPSW_E_INVALID_ARG;
    }

    unsigned int size = 0;
    unsigned char* data = NULL;
    int ret;

    *restore_plist = NULL;

    ret = ipsw_extract_to_memory(ipsw, "Restore.plist", &data, &size);
    if (ret == IPSW_E_SUCCESS) {
        plist_from_xml((char*)data, size, restore_plist);
        free(data);
        return IPSW_E_SUCCESS;
    }

    return ret;
}

static int ipsw_list_contents_recurse(ipsw_archive_t ipsw, const char *path, ipsw_list_cb cb, void *ctx)
{
	int ret = 0;
	char *base = build_path(ipsw->path, path);

	DIR *dirp = opendir(base);

	if (!dirp) {
		error("ERROR: failed to open directory %s\n", base);
		free(base);
		return -1;
	}

	while (ret >= 0) {
		struct dirent *dir = readdir(dirp);
		if (!dir)
			break;

		if (!strcmp(dir->d_name, ".") || !strcmp(dir->d_name, ".."))
			continue;

		char *fpath = build_path(base, dir->d_name);
		char *subpath;
		if (*path)
			subpath = build_path(path, dir->d_name);
		else
			subpath = strdup(dir->d_name);

		struct stat st;
#ifdef WIN32
		ret = stat(fpath, &st);
#else
		ret = lstat(fpath, &st);
#endif
		if (ret != 0) {
			error("ERROR: %s: stat failed for %s: %s\n", __func__, fpath, strerror(errno));
			free(fpath);
			free(subpath);
			break;
		}

		ret = cb(ctx, ipsw, subpath, &st);

		if (ret >= 0 && S_ISDIR(st.st_mode))
			ipsw_list_contents_recurse(ipsw, subpath, cb, ctx);

		free(fpath);
		free(subpath);
	}

	closedir(dirp);
	free(base);
	return ret;
}

int ipsw_list_contents(ipsw_archive_t ipsw, ipsw_list_cb cb, void *ctx)
{
	int ret = 0;

	if (ipsw == NULL) {
		error("ERROR: Invalid IPSW archive\n");
		return -1;
	}

	if (ipsw->zip) {
		int err = 0;
		struct zip *zip = zip_open(ipsw->path, 0, &err);
		if (zip == NULL) {
			error("ERROR: zip_open: %s: %d\n", ipsw->path, err);
			return -1;
		}

		int64_t entries = zip_get_num_entries(zip, 0);
		if (entries < 0) {
			error("ERROR: zip_get_num_entries failed\n");
			return -1;
		}

		for (int64_t index = 0; index < entries; index++) {
			zip_stat_t stat;

			zip_stat_init(&stat);
			if (zip_stat_index(zip, index, 0, &stat) < 0) {
				error("ERROR: zip_stat_index failed for %s\n", stat.name);
				ret = -1;
				continue;
			}

			uint8_t opsys;
			uint32_t attributes;
			if (zip_file_get_external_attributes(zip, index, 0, &opsys, &attributes) < 0) {
				error("ERROR: zip_file_get_external_attributes failed for %s\n", stat.name);
				ret = -1;
				continue;
			}
			if (opsys != ZIP_OPSYS_UNIX) {
				error("ERROR: File %s does not have UNIX attributes\n", stat.name);
				ret = -1;
				continue;
			}

			struct stat st;
			memset(&st, 0, sizeof(st));
			st.st_ino = 1 + index;
			st.st_nlink = 1;
			st.st_mode = attributes >> 16;
			st.st_size = stat.size;

			char *name = strdup(stat.name);
			if (name[strlen(name) - 1] == '/')
				name[strlen(name) - 1] = '\0';

			ret = cb(ctx, ipsw, name, &st);

			free(name);

			if (ret < 0)
				break;
		}
	} else {
		ret = ipsw_list_contents_recurse(ipsw, "", cb, ctx);
	}

	return ret;
}

int ipsw_get_signed_firmwares(const char* product, plist_t* firmwares)
{
	char url[256];
	char *jdata = NULL;
	uint32_t jsize = 0;
	plist_t dict = NULL;
	plist_t node = NULL;
	plist_t fws = NULL;
	const char* product_type = NULL;
	uint32_t count = 0;
	uint32_t i = 0;

	if (!product || !firmwares) {
		return -1;
	}

	*firmwares = NULL;
	snprintf(url, sizeof(url), "https://api.ipsw.me/v4/device/%s", product);

	if (download_to_buffer(url, &jdata, &jsize) < 0) {
		error("ERROR: Download from %s failed.\n", url);
		return -1;
	}
	plist_from_json(jdata, jsize, &dict);
	free(jdata);
	if (!dict || plist_get_node_type(dict) != PLIST_DICT) {
		error("ERROR: Failed to parse json data.\n");
		plist_free(dict);
		return -1;
	}

	node = plist_dict_get_item(dict, "identifier");
	if (!node || plist_get_node_type(node) != PLIST_STRING) {
		error("ERROR: Unexpected json data returned - missing 'identifier'\n");
		plist_free(dict);
		return -1;
	}
	product_type = plist_get_string_ptr(node, NULL);
	if (!product_type || strcmp(product_type, product) != 0) {
		error("ERROR: Unexpected json data returned - failed to read identifier\n");
		plist_free(dict);
		return -1;
	}
	fws = plist_dict_get_item(dict, "firmwares");
	if (!fws || plist_get_node_type(fws) != PLIST_ARRAY) {
		error("ERROR: Unexpected json data returned - missing 'firmwares'\n");
		plist_free(dict);
		return -1;
	}

	*firmwares = plist_new_array();
	count = plist_array_get_size(fws);
	for (i = 0; i < count; i++) {
		plist_t fw = plist_array_get_item(fws, i);
		node = plist_dict_get_item(fw, "signed");
		if (node && plist_get_node_type(node) == PLIST_BOOLEAN) {
			uint8_t bv = 0;
			plist_get_bool_val(node, &bv);
			if (bv) {
				plist_array_append_item(*firmwares, plist_copy(fw));
			}
		}
	}
	plist_free(dict);

	return 0;
}

int ipsw_get_latest_fw(plist_t version_data, const char* product, char** fwurl, unsigned char* sha1buf)
{
	*fwurl = NULL;
	if (sha1buf != NULL) {
		memset(sha1buf, '\0', 20);
	}

	plist_t n1 = plist_dict_get_item(version_data, "MobileDeviceSoftwareVersionsByVersion");
	if (!n1) {
		error("%s: ERROR: Can't find MobileDeviceSoftwareVersionsByVersion dict in version data\n", __func__);
		return -1;
	}

	plist_dict_iter iter = NULL;
	plist_dict_new_iter(n1, &iter);
	if (!iter) {
		error("%s: ERROR: Can't get dict iter\n", __func__);
		return -1;
	}
	char* key = NULL;
	uint64_t major = 0;
	plist_t val = NULL;
	do {
		plist_dict_next_item(n1, iter, &key, &val);
		if (key) {
			plist_t pr = plist_access_path(n1, 3, key, "MobileDeviceSoftwareVersions", product);
			if (pr) {
				long long unsigned int v = strtoull(key, NULL, 10);
				if (v > major)
					major = v;
			}
			free(key);
		}
	} while (val);
	free(iter);

	if (major == 0) {
		error("%s: ERROR: Can't find major version?!\n", __func__);
		return -1;
	}

	char majstr[32]; // should be enough for a uint64_t value
	snprintf(majstr, sizeof(majstr), "%"PRIu64, (uint64_t)major);
	n1 = plist_access_path(version_data, 7, "MobileDeviceSoftwareVersionsByVersion", majstr, "MobileDeviceSoftwareVersions", product, "Unknown", "Universal", "Restore");
	if (!n1) {
		error("%s: ERROR: Can't get Unknown/Universal/Restore node?!\n", __func__);
		return -1;
	}

	plist_t n2 = plist_dict_get_item(n1, "BuildVersion");
	if (!n2 || (plist_get_node_type(n2) != PLIST_STRING)) {
		error("%s: ERROR: Can't get build version node?!\n", __func__);
		return -1;
	}

	char* strval = NULL;
	plist_get_string_val(n2, &strval);

	n1 = plist_access_path(version_data, 5, "MobileDeviceSoftwareVersionsByVersion", majstr, "MobileDeviceSoftwareVersions", product, strval);
	if (!n1) {
		error("%s: ERROR: Can't get MobileDeviceSoftwareVersions/%s node?!\n", __func__, strval);
		free(strval);
		return -1;
	}
	free(strval);

	strval = NULL;
	n2 = plist_dict_get_item(n1, "SameAs");
	if (n2) {
		plist_get_string_val(n2, &strval);
	}
	if (strval) {
		n1 = plist_access_path(version_data, 5, "MobileDeviceSoftwareVersionsByVersion", majstr, "MobileDeviceSoftwareVersions", product, strval);
		free(strval);
		strval = NULL;
		if (!n1 || (plist_dict_get_size(n1) == 0)) {
			error("%s: ERROR: Can't get MobileDeviceSoftwareVersions/%s dict\n", __func__, product);
			return -1;
		}
	}

	n2 = plist_access_path(n1, 2, "Update", "BuildVersion");
	if (n2) {
		strval = NULL;
		plist_get_string_val(n2, &strval);
		if (strval) {
			n1 = plist_access_path(version_data, 5, "MobileDeviceSoftwareVersionsByVersion", majstr, "MobileDeviceSoftwareVersions", product, strval);
			free(strval);
			strval = NULL;
		}
	}

	n2 = plist_access_path(n1, 2, "Restore", "FirmwareURL");
	if (!n2 || (plist_get_node_type(n2) != PLIST_STRING)) {
		error("%s: ERROR: Can't get FirmwareURL node\n", __func__);
		return -1;
	}

	plist_get_string_val(n2, fwurl);

	if (sha1buf != NULL) {
		n2 = plist_access_path(n1, 2, "Restore", "FirmwareSHA1");
		if (n2 && plist_get_node_type(n2) == PLIST_STRING) {
			strval = NULL;
			plist_get_string_val(n2, &strval);
			if (strval) {
				if (strlen(strval) == 40) {
					int i;
					int v;
					for (i = 0; i < 40; i+=2) {
						v = 0;
						sscanf(strval+i, "%02x", &v);
						sha1buf[i/2] = (unsigned char)v;
					}
				}
				free(strval);
			}
		}
	}

	return 0;
}

// SHA1 验证辅助函数
static int sha1_verify_fp(FILE* f, unsigned char* expected_sha1)
{
    if (!f || !expected_sha1) {
        return 0;
    }

    unsigned char tsha1[20];
    char buf[8192];
    sha1_context sha1ctx;
    sha1_init(&sha1ctx);
    rewind(f);

    while (!feof(f)) {
        size_t sz = fread(buf, 1, sizeof(buf), f);
        sha1_update(&sha1ctx, buf, sz);
    }

    sha1_final(&sha1ctx, tsha1);
    return (memcmp(expected_sha1, tsha1, 20) == 0) ? 1 : 0;
}

int ipsw_download_fw(const char *fwurl, unsigned char* isha1, const char* todir, char** ipswfile)
{
	char* fwfn = strrchr(fwurl, '/');
	if (!fwfn) {
		error("ERROR: can't get local filename for firmware ipsw\n");
		return -2;
	}
	fwfn++;

	char fwlfn[PATH_MAX - 5];
	if (todir) {
		snprintf(fwlfn, sizeof(fwlfn), "%s/%s", todir, fwfn);
	} else {
		snprintf(fwlfn, sizeof(fwlfn), "%s", fwfn);
	}

	char fwlock[PATH_MAX];
	snprintf(fwlock, sizeof(fwlock), "%s.lock", fwlfn);

	lock_info_t lockinfo;

	if (lock_file(fwlock, &lockinfo) != 0) {
		error("WARNING: Could not lock file '%s'\n", fwlock);
	}

	int need_dl = 0;
	unsigned char zsha1[20] = {0, };
	FILE* f = fopen(fwlfn, "rb");
	if (f) {
		if (memcmp(zsha1, isha1, 20) != 0) {
			info("Verifying '%s'...\n", fwlfn);
			if (sha1_verify_fp(f, isha1)) {
				info("Checksum matches.\n");
			} else {
				info("Checksum does not match.\n");
				need_dl = 1;
			}
		}
		fclose(f);
	} else {
		need_dl = 1;
	}

	int res = 0;
	if (need_dl) {
		if (strncmp(fwurl, "protected:", 10) == 0) {
			error("ERROR: Can't download '%s' because it needs a purchase.\n", fwfn);
			res = -3;
		} else {
			remove(fwlfn);
			info("Downloading firmware (%s)\n", fwurl);
			download_to_file(fwurl, fwlfn, 1);
			if (memcmp(isha1, zsha1, 20) != 0) {
				info("\nVerifying '%s'...\n", fwlfn);
				FILE* f = fopen(fwlfn, "rb");
				if (f) {
					if (sha1_verify_fp(f, isha1)) {
						info("Checksum matches.\n");
					} else {
						error("ERROR: File download failed (checksum mismatch).\n");
						res = -4;
					}
					fclose(f);

					// make sure to remove invalid files
					if (res < 0)
						remove(fwlfn);
				} else {
					error("ERROR: Can't open '%s' for checksum verification\n", fwlfn);
					res = -5;
				}
			}
		}
	}
	if (res == 0) {
		*ipswfile = strdup(fwlfn);
	}

	if (unlock_file(&lockinfo) != 0) {
		error("WARNING: Could not unlock file '%s'\n", fwlock);
	}

	return res;
}

int ipsw_download_latest_fw(plist_t version_data, const char* product, const char* todir, char** ipswfile)
{
	char* fwurl = NULL;
	unsigned char isha1[20];

	*ipswfile = NULL;

	if ((ipsw_get_latest_fw(version_data, product, &fwurl, isha1) < 0) || !fwurl) {
		error("ERROR: can't get URL for latest firmware\n");
		return -1;
	}
	char* fwfn = strrchr(fwurl, '/');
	if (!fwfn) {
		error("ERROR: can't get local filename for firmware ipsw\n");
		return -2;
	}
	fwfn++;

	info("Latest firmware is %s\n", fwfn);

	int res = ipsw_download_fw(fwurl, isha1, todir, ipswfile);

	free(fwurl);

	return res;
}

// 取消操作实现
void ipsw_cancel(void)
{
	cancel_flag++;
}

// 文件句柄操作实现
ipsw_file_handle_t ipsw_file_open(ipsw_archive_t ipsw, const char* path)
{
    if (!ipsw || !path) {
        return NULL;
    }

    ipsw_file_handle_t handle = (ipsw_file_handle_t)calloc(1, sizeof(struct ipsw_file_handle));
    if (!handle) {
        return NULL;
    }

    if (ipsw->zip) {
        int err = 0;
        struct zip *zip = zip_open(ipsw->path, 0, &err);
        if (!zip) {
            error("ERROR: zip_open: %s: %d\n", ipsw->path, err);
            free(handle);
            return NULL;
        }

        int zindex = zip_name_locate(zip, path, 0);
        if (zindex < 0) {
            error("ERROR: zip_name_locate: %s not found\n", path);
            zip_close(zip);
            free(handle);
            return NULL;
        }

        // 检查是否需要解密
        const char* key = get_decryption_key(ipsw);
        if (key) {
            handle->zfile = zip_fopen_index_encrypted(zip, zindex, ZIP_FL_ENC_GUESS, key);
        } else {
            handle->zfile = zip_fopen_index(zip, zindex, 0);
        }

        if (!handle->zfile) {
            error("ERROR: zip_fopen_index: %s could not be opened\n", path);
            zip_close(zip);
            free(handle);
            return NULL;
        }

        struct zip_stat zst;
        zip_stat_init(&zst);
        zip_stat(zip, path, 0, &zst);
        handle->size = zst.size;
        handle->seekable = (zst.comp_method == ZIP_CM_STORE);
        handle->zip = zip;
    } else {

        char *filepath = build_path(ipsw->path, path);
        if (!filepath) {
            free(handle);
            return NULL;
        }

        handle->file = fopen(filepath, "rb");
        free(filepath);
        if (!handle->file) {
            free(handle);
            return NULL;
        }

        struct stat st;
        if (fstat(fileno(handle->file), &st) != 0) {
            fclose(handle->file);
            free(handle);
            return NULL;
        }
        handle->size = st.st_size;
        handle->seekable = 1;
    }

    return handle;
}


void ipsw_file_close(ipsw_file_handle_t handle)
{
    if (!handle) {
        return;
    }

    if (handle->zip) {
        if (handle->zfile) {
            zip_fclose(handle->zfile);
        }
        if (handle->zip) {
            zip_close(handle->zip);
        }
    } else if (handle->file) {
        fclose(handle->file);
    }
    free(handle);
}


uint64_t ipsw_file_size(ipsw_file_handle_t handle)
{
    if (!handle) {
        return 0;
    }
    return handle->size;
}

int64_t ipsw_file_read(ipsw_file_handle_t handle, void* buffer, size_t size)
{
	if (handle && handle->zfile) {
		zip_int64_t zr = zip_fread(handle->zfile, buffer, size);
		return (int64_t)zr;
	} else if (handle && handle->file) {
		return fread(buffer, 1, size, handle->file);
	} else {
		error("ERROR: %s: Invalid file handle\n", __func__);
		return -1;
	}
}

int ipsw_file_seek(ipsw_file_handle_t handle, int64_t offset, int whence)
{
	if (handle && handle->zfile) {
		return zip_fseek(handle->zfile, offset, whence);
	} else if (handle && handle->file) {
#ifdef WIN32
		if (whence == SEEK_SET) {
			rewind(handle->file);
		}
		return (_lseeki64(fileno(handle->file), offset, whence) < 0) ? -1 : 0;
#else
		return fseeko(handle->file, offset, whence);
#endif
	} else {
		error("ERROR: %s: Invalid file handle\n", __func__);
		return -1;
	}
}

int64_t ipsw_file_tell(ipsw_file_handle_t handle)
{
	if (handle && handle->zfile) {
		return zip_ftell(handle->zfile);
	} else if (handle && handle->file) {
#ifdef WIN32
		return _lseeki64(fileno(handle->file), 0, SEEK_CUR);
#else
		return ftello(handle->file);
#endif
	} else {
		error("ERROR: %s: Invalid file handle\n", __func__);
		return -1;
	}
}


// 错误代码转字符串
const char* ipsw_strerror(int errcode)
{
    switch (errcode) {
        case IPSW_E_SUCCESS:
            return "Success";
        case IPSW_E_INVALID_ARG:
            return "Invalid argument";
        case IPSW_E_NOT_FOUND:
            return "File not found";
        case IPSW_E_ENCRYPTED:
            return "File is encrypted";
        case IPSW_E_WRONG_PASSWORD:
            return "Wrong password";
        case IPSW_E_NO_MEMORY:
            return "Out of memory";
        case IPSW_E_CORRUPT:
            return "File is corrupt";
        case IPSW_E_IO_ERROR:
            return "I/O error";
        case IPSW_E_INVALID_PLIST:
            return "Plist parsing failed";
        case IPSW_E_CANCELED:
            return "Operation canceled";
        default:
            return "Unknown error";
    }
}
