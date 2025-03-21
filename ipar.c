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

#include <inttypes.h>
#include <openssl/aes.h>
#include <openssl/err.h>

#include <openssl/sha.h>
#include <CommonCrypto/CommonDigest.h>

#include <libimobiledevice-glue/termcolors.h>
#include <plist/plist.h>

#include "ipsw.h"
#include "locking.h"
#include "download.h"
#include "common.h"
#include "idevicerestore.h"


#define BUFSIZE 0x100000
#define TO_FILE_BLOCK_SIZE 32768 // 设定块大小

AES_KEY wctx;


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
    if (!ipsw) {
        error("ERROR: Invalid IPSW archive\n");
        return NULL;
    }

    // 如果文件未加密，无需密钥
    if (!ipsw->is_encrypted) {
        return NULL;
    }

    // 尝试从系统获取密钥
    const char* system_key = idevicerestore_get_decryption_key();
    if (system_key) {
        return system_key;
    }

    // 如果有回调函数，尝试获取密钥
    if (ipsw->key_callback) {
        const char* callback_key = ipsw->key_callback(ipsw->key_user_data);
        if (callback_key) {
            return callback_key;
        }
    }

    error("ERROR: Failed to get decryption key\n");
    return NULL;
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

    archive->is_encrypted = 0;

    if (S_ISDIR(fst.st_mode)) {
        archive->zip = 0;
        archive->key_callback = NULL;
        archive->key_user_data = NULL;
        info("DEBUG: IPSW is a directory, is_encrypted = %d\n", archive->is_encrypted);
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

        // 改进：实际检查ZIP文件是否加密
        struct zip_stat st;
        zip_stat_init(&st);
        
        // 检查第一个文件的加密状态
        if (zip_stat_index(zip, 0, 0, &st) == 0) {
            info("DEBUG: Checking encryption for first file: %s\n", st.name);
            info("DEBUG: Encryption method: %d\n", st.encryption_method);
            
            // 检查是否设置了加密标志
            if (st.encryption_method != ZIP_EM_NONE) {
                archive->is_encrypted = 1;
                
                // 如果文件加密但没有提供回调函数，发出警告
                if (!callback) {
                    info("WARNING: Encrypted IPSW detected but no decryption callback provided\n");
                }
            }
        }
        
        info("DEBUG: IPSW is a ZIP file, is_encrypted = %d\n", archive->is_encrypted);
    }

    archive->path = strdup(ipsw);
    info("DEBUG: Final encryption status for %s: is_encrypted = %d\n", ipsw, archive->is_encrypted);
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


// 文件大小获取实现
int ipsw_get_file_size(ipsw_archive_t ipsw, const char* infile, uint64_t* size)
{
	if (ipsw == NULL) {
		error("ERROR: Invalid archive\n");
		return -1;
	}

	if (ipsw->zip) {
		int err = 0;
		struct zip *zip = zip_open(ipsw->path, 0, &err);
		if (zip == NULL) {
			error("ERROR: zip_open: %s: %d\n", ipsw->path, err);
			return -1;
		}
		int zindex = zip_name_locate(zip, infile, 0);
		if (zindex < 0) {
			error("ERROR: zip_name_locate: %s\n", infile);
			zip_unchange_all(zip);
			zip_close(zip);
			return -1;
		}

		struct zip_stat zstat;
		zip_stat_init(&zstat);
		if (zip_stat_index(zip, zindex, 0, &zstat) != 0) {
			error("ERROR: zip_stat_index: %s\n", infile);
			zip_unchange_all(zip);
			zip_close(zip);
			return -1;
		}
		zip_unchange_all(zip);
		zip_close(zip);

		*size = zstat.size;
	} else {
		char *filepath = build_path(ipsw->path, infile);
		struct stat fst;
		if (stat(filepath, &fst) != 0) {
			free(filepath);
			return -1;
		}
		free(filepath);

		*size = fst.st_size;
	}

	return 0;
}


// 提取到文件的实现 - 修改后的版本
int ipsw_extract_to_file_with_progress(ipsw_archive_t ipsw, const char* infile, const char* outfile, int print_progress)
{
    int ret = 0;

    if (!ipsw || !infile || !outfile) {
        error("ERROR: Invalid argument\n");
        return -1;
    }

    cancel_flag = 0;

    if (ipsw->zip) {
        int err = 0;
        struct zip *zip = zip_open(ipsw->path, 0, &err);
        if (zip == NULL) {
            error("ERROR: zip_open: %s: %d\n", ipsw->path, err);
            return -1;
        }

        int zindex = zip_name_locate(zip, infile, 0);
        if (zindex < 0) {
            zip_unchange_all(zip);
            zip_close(zip);
            error("ERROR: zip_name_locate: %s\n", infile);
            return -1;
        }

        struct zip_stat zstat;
        zip_stat_init(&zstat);
        if (zip_stat_index(zip, zindex, 0, &zstat) != 0) {
            zip_unchange_all(zip);
            zip_close(zip);
            error("ERROR: zip_stat_index: %s\n", infile);
            return -1;
        }

        char* buffer = (char*) malloc(BUFSIZE);
        if (buffer == NULL) {
            zip_unchange_all(zip);
            zip_close(zip);
            error("ERROR: Unable to allocate memory\n");
            return -1;
        }

        struct zip_file* zfile = NULL;
        
        // 检查文件是否加密
        if (zstat.encryption_method != 0) {
            const char* key = idevicerestore_get_decryption_key();
            if (!key) {
                free(buffer);
                zip_unchange_all(zip);
                zip_close(zip);
                error("ERROR: No decryption key available for encrypted file: %s\n", infile);
                return -1;
            }
            //debug("1File '%s' is encrypted, attempting to open with key\n", infile);
            zfile = zip_fopen_index_encrypted(zip, zindex, ZIP_FL_ENC_GUESS, key);
        } else {
            zfile = zip_fopen_index(zip, zindex, 0);
        }

        if (zfile == NULL) {
            free(buffer);
            zip_unchange_all(zip);
            zip_close(zip);
            error("ERROR: zip_fopen_index: %s\n", infile);
            return -1;
        }

        FILE* fd = fopen(outfile, "wb");
        if (fd == NULL) {
            free(buffer);
            zip_fclose(zfile);
            zip_unchange_all(zip);
            zip_close(zip);
            error("ERROR: Unable to open output file: %s\n", outfile);
            return -1;
        }

        uint64_t i, bytes = 0;
        int count, size = BUFSIZE;
        double progress;
        for(i = zstat.size; i > 0; i -= count) {
            if (cancel_flag) {
                break;
            }
            if (i < BUFSIZE)
                size = i;
            count = zip_fread(zfile, buffer, size);
            if (count < 0) {
                int zep = 0;
                int sep = 0;
                zip_file_error_get(zfile, &zep, &sep);
                error("ERROR: zip_fread: %s %d %d\n", infile, zep, sep);
                ret = -1;
                break;
            }
            if (fwrite(buffer, 1, count, fd) != count) {
                error("ERROR: Writing to '%s' failed: %s\n", outfile, strerror(errno));
                ret = -1;
                break;
            }

            bytes += size;
            if (print_progress) {
                progress = ((double)bytes / (double)zstat.size) * 100.0;
                print_progress_bar(progress);
            }
        }
        free(buffer);
        fclose(fd);
        zip_fclose(zfile);
        zip_unchange_all(zip);
        zip_close(zip);
    } else {
        char *filepath = build_path(ipsw->path, infile);
        char actual_filepath[PATH_MAX+1];
        char actual_outfile[PATH_MAX+1];
        if (!filepath) {
            ret = -1;
            goto leave;
        }
        if (!realpath(filepath, actual_filepath)) {
            error("ERROR: realpath failed on %s: %s\n", filepath, strerror(errno));
            ret = -1;
            goto leave;
        } else {
            actual_outfile[0] = '\0';
            if (realpath(outfile, actual_outfile) && (strcmp(actual_filepath, actual_outfile) == 0)) {
                /* files are identical */
                ret = 0;
            } else {
                if (actual_outfile[0] == '\0') {
                    strcpy(actual_outfile, outfile);
                }
                FILE *fi = fopen(actual_filepath, "rb");
                if (!fi) {
                    error("ERROR: fopen: %s: %s\n", actual_filepath, strerror(errno));
                    ret = -1;
                    goto leave;
                }
                struct stat fst;
                if (fstat(fileno(fi), &fst) != 0) {
                    fclose(fi);
                    error("ERROR: fstat: %s: %s\n", actual_filepath, strerror(errno));
                    ret = -1;
                    goto leave;
                }
                FILE *fo = fopen(actual_outfile, "wb");
                if (!fo) {
                    fclose(fi);
                    error("ERROR: fopen: %s: %s\n", actual_outfile, strerror(errno));
                    ret = -1;
                    goto leave;
                }
                char* buffer = (char*) malloc(BUFSIZE);
                if (buffer == NULL) {
                    fclose(fi);
                    fclose(fo);
                    error("ERROR: Unable to allocate memory\n");
                    ret = -1;
                    goto leave;
                }

                uint64_t bytes = 0;
                double progress;
                while (!feof(fi)) {
                    if (cancel_flag) {
                        break;
                    }
                    ssize_t r = fread(buffer, 1, BUFSIZE, fi);
                    if (r < 0) {
                        error("ERROR: fread failed: %s\n", strerror(errno));
                        ret = -1;
                        break;
                    }
                    if (fwrite(buffer, 1, r, fo) != r) {
                        error("ERROR: Writing to '%s' failed: %s\n", actual_outfile, strerror(errno));
                        ret = -1;
                        break;
                    }
                    bytes += r;
                    if (print_progress) {
                        progress = ((double)bytes / (double)fst.st_size) * 100.0;
                        print_progress_bar(progress);
                    }
                }

                free(buffer);
                fclose(fi);
                fclose(fo);
            }
        }
    leave:
        free(filepath);
    }
    if (cancel_flag) {
        ret = -2;
    }
    return ret;
}


// 无进度条提取实现
int ipsw_extract_to_file(ipsw_archive_t ipsw, const char* infile, const char* outfile)
{
	return ipsw_extract_to_file_with_progress(ipsw, infile, outfile, 0);
}


// 文件是否存在检查实现
int ipsw_file_exists(ipsw_archive_t ipsw, const char* infile)
{
	if (!ipsw) {
		return 0;
	}

	if (ipsw->zip) {
		int err = 0;
		struct zip *zip = zip_open(ipsw->path, 0, &err);
		if (zip == NULL) {
			error("ERROR: zip_open: %s: %d\n", ipsw->path, err);
			return 0;
		}
		int zindex = zip_name_locate(zip, infile, 0);
		zip_unchange_all(zip);
		zip_close(zip);
		if (zindex < 0) {
			return 0;
		}
	} else {
		char *filepath = build_path(ipsw->path, infile);
		if (access(filepath, R_OK) != 0) {
			free(filepath);
			return 0;
		}
		free(filepath);
	}

	return 1;
}



/* 提取 IPSW 文件到内存，支持 ZIP 解密 */
int ipsw_extract_to_memory(ipsw_archive_t ipsw, const char* infile, unsigned char** pbuffer, unsigned int* psize)
{
	size_t size = 0;
	unsigned char* buffer = NULL;
	if (ipsw == NULL) {
		error("ERROR: Invalid archive\n");
		return -1;
	}

	if (ipsw->zip) {
		int err = 0;
		struct zip *zip = zip_open(ipsw->path, 0, &err);
		if (zip == NULL) {
			error("ERROR: zip_open: %s: %d\n", ipsw->path, err);
			return -1;
		}

		int zindex = zip_name_locate(zip, infile, 0);
		if (zindex < 0) {
			zip_unchange_all(zip);
			zip_close(zip);
			debug("NOTE: zip_name_locate: '%s' not found in archive.\n", infile);
			return -1;
		}

		struct zip_stat zstat;
		zip_stat_init(&zstat);
		if (zip_stat_index(zip, zindex, 0, &zstat) != 0) {
			zip_unchange_all(zip);
			zip_close(zip);
			error("ERROR: zip_stat_index: %s\n", infile);
			return -1;
		}

        struct zip_file* zfile = NULL;
        
        // 检查文件是否加密
        if (zstat.encryption_method != 0) {
            const char* key = idevicerestore_get_decryption_key();
            if (!key) {
                free(buffer);
                zip_unchange_all(zip);
                zip_close(zip);
                error("ERROR: No decryption key available for encrypted file: %s\n", infile);
                return -1;
            }
            //debug("1File '%s' is encrypted, attempting to open with key\n", infile);
            zfile = zip_fopen_index_encrypted(zip, zindex, ZIP_FL_ENC_GUESS, key);
        } else {
            zfile = zip_fopen_index(zip, zindex, 0);
        }



		if (zfile == NULL) {
			free(buffer);
			zip_unchange_all(zip);
			zip_close(zip);
			error("ERROR: zip_fopen_index: %s\n", infile);
			return -1;
		}

		size = zstat.size;
		buffer = (unsigned char*) malloc(size+1);
		if (buffer == NULL) {
			error("ERROR: Out of memory\n");
			zip_fclose(zfile);
			zip_unchange_all(zip);
			zip_close(zip);
			return -1;
		}

		zip_int64_t zr = zip_fread(zfile, buffer, size);
		zip_fclose(zfile);
		zip_unchange_all(zip);
		zip_close(zip);
		if (zr < 0) {
			int zep = 0;
			int sep = 0;
			zip_file_error_get(zfile, &zep, &sep);
			error("ERROR: zip_fread: %s %d %d\n", infile, zep, sep);
			free(buffer);
			return -1;
		} else if (zr != size) {
			error("ERROR: zip_fread: %s got only %lld of %zu\n", infile, zr, size);
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
			error("ERROR: %s: stat failed for %s: %s\n", __func__, filepath, strerror(errno));
			free(filepath);
			return -1;
		}
		size = fst.st_size;
		buffer = (unsigned char*)malloc(size+1);
		if (buffer == NULL) {
			error("ERROR: Out of memory\n");
			free(filepath);
			return -1;
		}

#ifndef WIN32
		if (S_ISLNK(fst.st_mode)) {
			if (readlink(filepath, (char*)buffer, size) < 0) {
				error("ERROR: %s: readlink failed for %s: %s\n", __func__, filepath, strerror(errno));
				free(filepath);
				free(buffer);
				return -1;
			}
		} else {
#endif
			FILE *f = fopen(filepath, "rb");
			if (!f) {
				error("ERROR: %s: fopen failed for %s: %s\n", __func__, filepath, strerror(errno));
				free(filepath);
				free(buffer);
				return -2;
			}
			if (fread(buffer, 1, size, f) != size) {
				fclose(f);
				error("ERROR: %s: fread failed for %s: %s\n", __func__, filepath, strerror(errno));
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



// 发送文件实现
int ipsw_extract_send(ipsw_archive_t ipsw, const char* infile, int blocksize, ipsw_send_cb send_callback, void* ctx)
{
	unsigned char* buffer = NULL;
	size_t done = 0;
	size_t total_size = 0;

	if (ipsw == NULL) {
		error("ERROR: Invalid archive\n");
		return -1;
	}

	if (ipsw->zip) {
		int err = 0;
		struct zip *zip = zip_open(ipsw->path, 0, &err);
		if (zip == NULL) {
			error("ERROR: zip_open: %s: %d\n", ipsw->path, err);
			return -1;
		}

		int zindex = zip_name_locate(zip, infile, 0);
		if (zindex < 0) {
			zip_unchange_all(zip);
			zip_close(zip);
			debug("NOTE: zip_name_locate: '%s' not found in archive.\n", infile);
			return -1;
		}

		struct zip_stat zstat;
		zip_stat_init(&zstat);
		if (zip_stat_index(zip, zindex, 0, &zstat) != 0) {
			zip_unchange_all(zip);
			zip_close(zip);
			error("ERROR: zip_stat_index: %s\n", infile);
			return -1;
		}

        struct zip_file* zfile = NULL;
        
        // 检查文件是否加密
        if (zstat.encryption_method != 0) {
            const char* key = idevicerestore_get_decryption_key();
            if (!key) {
                zip_unchange_all(zip);
                zip_close(zip);
                error("ERROR: No decryption key available for encrypted file: %s\n", infile);
                return -1;
            }
           //debug("0File '%s' is encrypted, attempting to open with key\n", infile);
            zfile = zip_fopen_index_encrypted(zip, zindex, ZIP_FL_ENC_GUESS, key);
        } else {
            zfile = zip_fopen_index(zip, zindex, 0);
        }


		if (zfile == NULL) {
			zip_unchange_all(zip);
			zip_close(zip);
			error("ERROR: zip_fopen_index: %s\n", infile);
			return -1;
		}

		total_size = zstat.size;
		buffer = (unsigned char*) malloc(blocksize);
		if (buffer == NULL) {
			zip_fclose(zfile);
			zip_unchange_all(zip);
			zip_close(zip);
			error("ERROR: Out of memory\n");
			return -1;
		}

		while (done < total_size) {
			size_t size = total_size-done;
			if (size > blocksize) size = blocksize;
			zip_int64_t zr = zip_fread(zfile, buffer, size);
			if (zr < 0) {
				error("ERROR: %s: zip_fread: %s\n", __func__, infile);
				break;
			} else if (zr == 0) {
				// EOF
				break;
			}
			if (send_callback(ctx, buffer, zr, done, total_size) < 0) {
				error("ERROR: %s: send failed\n", __func__);
				break;
			}
			done += zr;
		}
		free(buffer);
		zip_fclose(zfile);
		zip_unchange_all(zip);
		zip_close(zip);
	} else {
		char *filepath = build_path(ipsw->path, infile);
		struct stat fst;
#ifdef WIN32
		if (stat(filepath, &fst) != 0) {
#else
		if (lstat(filepath, &fst) != 0) {
#endif
			error("ERROR: %s: stat failed for %s: %s\n", __func__, filepath, strerror(errno));
			free(filepath);
			return -1;
		}
		total_size = fst.st_size;
		buffer = (unsigned char*)malloc(blocksize);
		if (buffer == NULL) {
			error("ERROR: Out of memory\n");
			free(filepath);
			return -1;
		}

#ifndef WIN32
		if (S_ISLNK(fst.st_mode)) {
			ssize_t rl = readlink(filepath, (char*)buffer, (total_size > blocksize) ? blocksize : total_size);
			if (rl < 0) {
				error("ERROR: %s: readlink failed for %s: %s\n", __func__, filepath, strerror(errno));
				free(filepath);
				free(buffer);
				return -1;
			}
			send_callback(ctx, buffer, (size_t)rl, 0, 0);
		} else {
#endif
			FILE *f = fopen(filepath, "rb");
			if (!f) {
				error("ERROR: %s: fopen failed for %s: %s\n", __func__, filepath, strerror(errno));
				free(filepath);
				free(buffer);
				return -2;
			}

			while (done < total_size) {
				size_t size = total_size-done;
				if (size > blocksize) size = blocksize;
				size_t fr = fread(buffer, 1, size, f);
				if (fr != size) {
					error("ERROR: %s: fread failed for %s: %s\n", __func__, filepath, strerror(errno));
					break;
				}
				if (send_callback(ctx, buffer, fr, done, total_size) < 0) {
					error("ERROR: %s: send failed\n", __func__);
					break;
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
		error("ERROR: %s: Sending file data for %s failed (sent %" PRIu64 "/%" PRIu64 ")\n", __func__, infile, (uint64_t)done, (uint64_t)total_size);
		return -1;
	}

	// send a NULL buffer to mark end of transfer
	send_callback(ctx, NULL, 0, done, total_size);

	return 0;
}


// BuildManifest 提取实现
int ipsw_extract_build_manifest(ipsw_archive_t ipsw, plist_t* buildmanifest, int *tss_enabled)
{
	unsigned int size = 0;
	unsigned char* data = NULL;

	*tss_enabled = 0;

	/* older devices don't require personalized firmwares and use a BuildManifesto.plist */
	if (ipsw_file_exists(ipsw, "BuildManifesto.plist")) {
		if (ipsw_extract_to_memory(ipsw, "BuildManifesto.plist", &data, &size) == 0) {
			plist_from_xml((char*)data, size, buildmanifest);
			free(data);
			return 0;
		}
	}

	data = NULL;
	size = 0;

	/* whereas newer devices do not require personalized firmwares and use a BuildManifest.plist */
	if (ipsw_extract_to_memory(ipsw, "BuildManifest.plist", &data, &size) == 0) {
		*tss_enabled = 1;
		plist_from_xml((char*)data, size, buildmanifest);
		free(data);
		return 0;
	}

	return -1;
}



// Restore.plist 提取实现
int ipsw_extract_restore_plist(ipsw_archive_t ipsw, plist_t* restore_plist)
{
	unsigned int size = 0;
	unsigned char* data = NULL;

	if (ipsw_extract_to_memory(ipsw, "Restore.plist", &data, &size) == 0) {
		plist_from_xml((char*)data, size, restore_plist);
		free(data);
		return 0;
	}

	return -1;
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
    unsigned char tsha1[CC_SHA1_DIGEST_LENGTH];
    char buf[8192];
    if (!f) return 0;
    CC_SHA1_CTX sha1ctx;
    CC_SHA1_Init(&sha1ctx);
    rewind(f);
    while (!feof(f)) {
        size_t sz = fread(buf, 1, 8192, f);
        CC_SHA1_Update(&sha1ctx, (const void*)buf, (CC_LONG)sz);
    }
    CC_SHA1_Final(tsha1, &sha1ctx);
    return (memcmp(expected_sha1, tsha1, CC_SHA1_DIGEST_LENGTH) == 0) ? 1 : 0;
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
	ipsw_file_handle_t handle = (ipsw_file_handle_t)calloc(1, sizeof(struct ipsw_file_handle));
	if (!handle) {
		error("ERROR: Out of memory\n");
		return NULL;
	}

	if (ipsw->zip) {
		int err = 0;
		struct zip *zip = zip_open(ipsw->path, 0, &err);
		if (zip == NULL) {
			error("ERROR: zip_open: %s: %d\n", ipsw->path, err);
			free(handle);
			return NULL;
		}

		zip_int64_t zindex = zip_name_locate(zip, path, 0);
		if (zindex < 0) {
			error("ERROR: zip_name_locate: %s not found\n", path);
			zip_unchange_all(zip);
			zip_close(zip);
			free(handle);
			return NULL;
		}

		zip_stat_t zst;
		zip_stat_init(&zst);
		if (zip_stat_index(zip, zindex, 0, &zst) != 0) {
			error("ERROR: zip_stat_index failed for %s\n", path);
			zip_unchange_all(zip);
			zip_close(zip);
			free(handle);
			return NULL;
		}


        handle->size = zst.size;
        handle->seekable = (zst.comp_method == ZIP_CM_STORE);
        handle->zip = zip;
        handle->is_encrypted = (zst.encryption_method != 0) ? 1 : 0;
		handle->archive = ipsw;

		// Debug 压缩方式
		debug("zip_stat: comp_method = %d, size = %" PRIu64 ", encrypted = %d\n",
		      zst.comp_method, zst.size, zst.encryption_method);

		// 检查文件是否加密
		if (zst.encryption_method != 0) {
			const char* key = idevicerestore_get_decryption_key();
			if (!key) {
				error("ERROR: No decryption key available for encrypted file: %s\n", path);
				zip_unchange_all(zip);
				zip_close(zip);
				free(handle);
				return NULL;
			}

			if (strstr(path, ".dmg") != NULL) {
				info("Opening encrypted DMG file: %s\n", path);
			}

			handle->zfile = zip_fopen_index_encrypted(zip, zindex, 0, key); // no ZIP_FL_ENC_GUESS
		} else {
			handle->zfile = zip_fopen_index(zip, zindex, 0);
		}

		if (!handle->zfile) {
			error("ERROR: zip_fopen_index: %s could not be opened\n", path);
			zip_unchange_all(zip);
			zip_close(zip);
			free(handle);
			return NULL;
		}
	} else {
		struct stat st;
		char *filepath = build_path(ipsw->path, path);
		handle->file = fopen(filepath, "rb");
		free(filepath);
		if (!handle->file) {
			error("ERROR: fopen: %s could not be opened\n", path);
			free(handle);
			return NULL;
		}
		fstat(fileno(handle->file), &st);
		handle->size = st.st_size;
		handle->seekable = 1;
	}

	return handle;
}


void ipsw_file_close(ipsw_file_handle_t handle)
{
	if (handle && handle->zfile) {
		zip_fclose(handle->zfile);
		zip_unchange_all(handle->zip);
		zip_close(handle->zip);
	} else if (handle && handle->file) {
		fclose(handle->file);
	}
	free(handle);
}


uint64_t ipsw_file_size(ipsw_file_handle_t handle)
{
	if (handle) {
		return handle->size;
	}
	return 0;
}


int64_t ipsw_file_read(ipsw_file_handle_t handle, void* buffer, size_t size)
{
	if (!handle) {
		error("ERROR: %s: Invalid file handle\n", __func__);
		return -1;
	}

	if (handle->archive && handle->archive->is_encrypted && handle->file) {
		uint8_t* dst = (uint8_t*)buffer;
		uint64_t total_read = 0;
		unsigned char iv[AES_BLOCK_SIZE];
		unsigned char encrypted_block[TO_FILE_BLOCK_SIZE];
		unsigned char decrypted_block[TO_FILE_BLOCK_SIZE];

		while (total_read < size) {
			memset(iv, 0, AES_BLOCK_SIZE);

			off_t cur_pos = ftello(handle->file);
			size_t remaining = handle->size - cur_pos;
			if (remaining == 0) break;

			size_t to_read = (remaining >= TO_FILE_BLOCK_SIZE) ? TO_FILE_BLOCK_SIZE : remaining;

			// AES CBC 要求长度必须为 16 的倍数
			if (to_read % AES_BLOCK_SIZE != 0) {
				to_read = (to_read / AES_BLOCK_SIZE) * AES_BLOCK_SIZE;
			}

			if (to_read == 0) break;

			size_t actual_read = fread(encrypted_block, 1, to_read, handle->file);
			if (actual_read == 0) break;

			AES_cbc_encrypt(encrypted_block, decrypted_block, actual_read, &wctx, iv, AES_DECRYPT);

			size_t skip = handle->seek_block_index;
			size_t copy_size = actual_read - skip;

			if (copy_size > (size - total_read)) {
				copy_size = size - total_read;
			}

			memcpy(dst + total_read, decrypted_block + skip, copy_size);
			total_read += copy_size;

			handle->seek_block_index = 0;
		}

		return total_read;
	}

	// 非加密情况
	if (handle->zfile) {
		return (int64_t)zip_fread(handle->zfile, buffer, size);
	} else if (handle->file) {
		return fread(buffer, 1, size, handle->file);
	}

	error("ERROR: %s: Invalid file handle\n", __func__);
	return -1;
}



int ipsw_file_seek(ipsw_file_handle_t handle, int64_t offset, int whence)
{
	if (!handle) {
		error("ERROR: %s: Invalid file handle\n", __func__);
		return -1;
	}


	// 对于 ZIP 压缩包中未加密的、可 seek 的文件，使用 zip_fseek（需系统支持）
	// 精确判断：只有在未压缩且未加密时才可 zip_fseek
	//if (handle->zfile && handle->seekable) {
		info("Trying zip_fseek(offset=0x%" PRIx64 ", whence=%d)\n", offset, whence);
		zip_int8_t rc = zip_fseek(handle->zfile, offset, whence);
		if (rc != 0) {
			error("zip_fseek failed at offset 0x%" PRIx64 " with whence=%d\n", offset, whence);
			return -1; // ✅ 必须中断，防止后续读取崩溃
		} else {
			info("zip_fseek successful\n");
			return 0;
		}
	//}

	// 对于加密的文件（外部 DMG 解密）
	if (handle->archive && handle->archive->is_encrypted) {
		if (handle->file) {



			if (whence != SEEK_SET) {
				info("ERROR: Encrypted seek only supports SEEK_SET\n");
				return -1;
			}

			int64_t aligned_offset = (offset / TO_FILE_BLOCK_SIZE) * TO_FILE_BLOCK_SIZE;
			handle->seek_block_index = offset % TO_FILE_BLOCK_SIZE;

			if (aligned_offset >= handle->size) {
				info("ERROR: Encrypted seek aligned offset out of bounds: 0x%" PRIx64 " (file size: 0x%" PRIx64 ")\n",
					aligned_offset, handle->size);
				return -1;
			}

			if (fseeko(handle->file, aligned_offset, SEEK_SET) < 0) {
				info("ERROR: fseeko failed to 0x%" PRIx64 ": %s\n", aligned_offset, strerror(errno));
				return -1;
			}
			return 0;
		} else {
			info("ERROR: Cannot seek inside encrypted zip stream: %s\n", handle->archive->path);
			return -1;
		}
	}

	// 普通的文件
	if (handle->file) {
#ifdef WIN32
		if (whence == SEEK_SET) rewind(handle->file);
		return (_lseeki64(fileno(handle->file), offset, whence) < 0) ? -1 : 0;
#else
		return fseeko(handle->file, offset, whence);
#endif
	}

	// 如果 zfile 存在但不可 seek（压缩方式不支持），也要给出提示
	if (handle->zfile && !handle->seekable) {
		info("ERROR: zip_fseek not supported for compressed file in zip: %s\n", handle->archive->path);
		return -1;
	}

	error("ERROR: %s: Invalid file handle\n", __func__);
	return -1;
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




/*
 * asr.c
 * Functions for handling asr connections
 *
 * Copyright (c) 2010-2012 Martin Szulecki. All Rights Reserved.
 * Copyright (c) 2012 Nikias Bassen. All Rights Reserved.
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
#include <libimobiledevice/libimobiledevice.h>
#ifdef HAVE_OPENSSL
#include <openssl/sha.h>
#else
#include "sha1.h"
#define SHA_CTX SHA1_CTX
#define SHA1_Init SHA1Init
#define SHA1_Update SHA1Update
#define SHA1_Final SHA1Final
#endif

#include "asr.h"
#include "idevicerestore.h"
#include "common.h"
#include "ipsw.h"

#define ASR_VERSION 1
#define ASR_STREAM_ID 1
#define ASR_PORT 12345
#define ASR_BUFFER_SIZE 65536
#define ASR_FEC_SLICE_STRIDE 40
#define ASR_PACKETS_PER_FEC 25
#define ASR_PAYLOAD_PACKET_SIZE 1450
#define ASR_PAYLOAD_CHUNK_SIZE 131072
#define ASR_CHECKSUM_CHUNK_SIZE 131072

int asr_open_with_timeout(idevice_t device, asr_client_t* asr)
{
	int i = 0;
	int attempts = 10;
	idevice_connection_t connection = NULL;
	idevice_error_t device_error = IDEVICE_E_SUCCESS;

	*asr = NULL;

	if (device == NULL) {
		return -1;
	}

	debug("Connecting to ASR\n");
	for (i = 1; i <= attempts; i++) {
		device_error = idevice_connect(device, ASR_PORT, &connection);
		if (device_error == IDEVICE_E_SUCCESS) {
			break;
		}

		if (i >= attempts) {
			error("ERROR: Unable to connect to ASR client\n");
			return -1;
		}

		sleep(2);
		debug("Retrying connection...\n");
	}

	asr_client_t asr_loc = (asr_client_t)malloc(sizeof(struct asr_client));
	memset(asr_loc, '\0', sizeof(struct asr_client));
	asr_loc->connection = connection;

	/* receive Initiate command message */
	plist_t data = NULL;
	asr_loc->checksum_chunks = 0;
	if (asr_receive(asr_loc, &data) < 0) {
		error("ERROR: Unable to receive data from ASR\n");
		asr_free(asr_loc);
		plist_free(data);
		return -1;
	}
	plist_t node;
	node = plist_dict_get_item(data, "Command");
	if (node && (plist_get_node_type(node) == PLIST_STRING)) {
		char* strval = NULL;
		plist_get_string_val(node, &strval);
		if (strval && (strcmp(strval, "Initiate") != 0)) {
			error("ERROR: unexpected ASR plist received:\n");
			debug_plist(data);
			plist_free(data);
			asr_free(asr_loc);
			return -1;
		}
	}

	node = plist_dict_get_item(data, "Checksum Chunks");
	if (node && (plist_get_node_type(node) == PLIST_BOOLEAN)) {
		plist_get_bool_val(node, &(asr_loc->checksum_chunks));
	}
	plist_free(data);

	*asr = asr_loc;

	return 0;
}

void asr_set_progress_callback(asr_client_t asr, asr_progress_cb_t cbfunc, void* userdata)
{
	if (!asr) {
		return;
	}
	asr->progress_cb = cbfunc;
	asr->progress_cb_data = userdata;
}

int asr_receive(asr_client_t asr, plist_t* data)
{
	uint32_t size = 0;
	char* buffer = NULL;
	plist_t request = NULL;
	idevice_error_t device_error = IDEVICE_E_SUCCESS;

	*data = NULL;

	buffer = (char*)malloc(ASR_BUFFER_SIZE);
	if (buffer == NULL) {
		error("ERROR: Unable to allocate memory for ASR receive buffer\n");
		return -1;
	}

	device_error = idevice_connection_receive(asr->connection, buffer, ASR_BUFFER_SIZE, &size);
	if (device_error != IDEVICE_E_SUCCESS) {
		error("ERROR: Unable to receive data from ASR\n");
		free(buffer);
		return -1;
	}
	plist_from_xml(buffer, size, &request);

	*data = request;

	debug("Received %d bytes:\n", size);
	if (idevicerestore_debug)
		debug_plist(request);
	free(buffer);
	return 0;
}

int asr_send(asr_client_t asr, plist_t data)
{
	uint32_t size = 0;
	char* buffer = NULL;

	plist_to_xml(data, &buffer, &size);
	if (asr_send_buffer(asr, buffer, size) < 0) {
		error("ERROR: Unable to send plist to ASR\n");
		free(buffer);
		return -1;
	}

	if (buffer)
		free(buffer);
	return 0;
}

int asr_send_buffer(asr_client_t asr, const char* data, uint32_t size)
{
	uint32_t bytes = 0;
	idevice_error_t device_error = IDEVICE_E_SUCCESS;

	device_error = idevice_connection_send(asr->connection, data, size, &bytes);
	if (device_error != IDEVICE_E_SUCCESS || bytes != size) {
		error("ERROR: Unable to send data to ASR. Sent %u of %u bytes.\n", bytes, size);
		return -1;
	}

	return 0;
}

void asr_free(asr_client_t asr)
{
	if (asr != NULL) {
		if (asr->connection != NULL) {
			idevice_disconnect(asr->connection);
			asr->connection = NULL;
		}
		free(asr);
		asr = NULL;
	}
}

int asr_send_validation_packet_info(asr_client_t asr, uint64_t ipsw_size)
{
	plist_t payload_info = plist_new_dict();
	plist_dict_set_item(payload_info, "Port", plist_new_uint(1));
	plist_dict_set_item(payload_info, "Size", plist_new_uint(ipsw_size));

	plist_t packet_info = plist_new_dict();
	if (asr->checksum_chunks) {
		plist_dict_set_item(packet_info, "Checksum Chunk Size", plist_new_uint(ASR_CHECKSUM_CHUNK_SIZE));
	}
	plist_dict_set_item(packet_info, "FEC Slice Stride", plist_new_uint(ASR_FEC_SLICE_STRIDE));
	plist_dict_set_item(packet_info, "Packet Payload Size", plist_new_uint(ASR_PAYLOAD_PACKET_SIZE));
	plist_dict_set_item(packet_info, "Packets Per FEC", plist_new_uint(ASR_PACKETS_PER_FEC));
	plist_dict_set_item(packet_info, "Payload", payload_info);
	plist_dict_set_item(packet_info, "Stream ID", plist_new_uint(ASR_STREAM_ID));
	plist_dict_set_item(packet_info, "Version", plist_new_uint(ASR_VERSION));

	if (asr_send(asr, packet_info)) {
		plist_free(packet_info);
		return -1;
	}
	plist_free(packet_info);

	return 0;
}

int asr_perform_validation(asr_client_t asr, ipsw_file_handle_t file)
{
	uint64_t length = 0;
	char* command = NULL;
	plist_t node = NULL;
	plist_t packet = NULL;
	int attempts = 0;

	length = ipsw_file_size(file);

	// Expected by device after every initiate
	if (asr_send_validation_packet_info(asr, length) < 0) {
		error("ERROR: Unable to send validation packet info to ASR\n");
		return -1;
	}

	while (1) {
		if (asr_receive(asr, &packet) < 0) {
			error("ERROR: Unable to receive validation packet\n");
			return -1;
		}

		if (packet == NULL) {
			if (attempts < 5) {
				info("Retrying to receive validation packet... %d\n", attempts);
				attempts++;
				sleep(1);
				continue;
			}
		}

		attempts = 0;

		node = plist_dict_get_item(packet, "Command");
		if (!node || plist_get_node_type(node) != PLIST_STRING) {
			error("ERROR: Unable to find command node in validation request\n");
			return -1;
		}
		plist_get_string_val(node, &command);

		// Added for iBridgeOS 9.0 - second initiate request to change to checksum chunks
		if (!strcmp(command, "Initiate")) {
			// This might switch on the second Initiate
			node = plist_dict_get_item(packet, "Checksum Chunks");
			if (node && (plist_get_node_type(node) == PLIST_BOOLEAN)) {
				plist_get_bool_val(node, &(asr->checksum_chunks));
			}
			plist_free(packet);

			// Expected by device after every Initiate
			if (asr_send_validation_packet_info(asr, length) < 0) {
				error("ERROR: Unable to send validation packet info to ASR\n");
				return -1;
			}

			// A OOBData request should follow
			continue;
		}

		if (!strcmp(command, "OOBData")) {
			int ret = asr_handle_oob_data_request(asr, packet, file);
			plist_free(packet);
			if (ret < 0)
				return ret;
		} else if(!strcmp(command, "Payload")) {
			plist_free(packet);
			break;

		} else {
			error("ERROR: Unknown command received from ASR\n");
			plist_free(packet);
			return -1;
		}
	}

	return 0;
}



int asr_handle_oob_data_request(asr_client_t asr, plist_t packet, ipsw_file_handle_t file)
{
	char* oob_data = NULL;
	uint64_t oob_offset = 0;
	uint64_t oob_length = 0;
	plist_t oob_length_node = NULL;
	plist_t oob_offset_node = NULL;



	oob_length_node = plist_dict_get_item(packet, "OOB Length");
	if (!oob_length_node || PLIST_UINT != plist_get_node_type(oob_length_node)) {
		info("ERROR: Unable to find OOB data length\n");
		return -1;
	}
	plist_get_uint_val(oob_length_node, &oob_length);

	oob_offset_node = plist_dict_get_item(packet, "OOB Offset");
	if (!oob_offset_node || PLIST_UINT != plist_get_node_type(oob_offset_node)) {
		info("ERROR: Unable to find OOB data offset\n");
		return -1;
	}
	plist_get_uint_val(oob_offset_node, &oob_offset);


	uint64_t filesize = ipsw_file_size(file);
	info("DEBUG: Using file: %s\n", file->archive->path);
	info("DEBUG: seekable = %d, encrypted = %d, file = %p, zfile = %p\n", file->seekable, file->archive->is_encrypted, file->file, file->zfile);

	info("DEBUG: OOB Offset = 0x%" PRIx64 ", Length = 0x%" PRIx64 ", FileSize = 0x%" PRIx64 "\n",
	     oob_offset, oob_length, filesize);

	if (oob_offset + oob_length > filesize) {
		error("ERROR: OOB offset+length exceeds file size\n");
		return -1;
	}



	oob_data = (char*) malloc(oob_length);
	if (oob_data == NULL) {
		error("ERROR: Out of memory\n");
		return -1;
	}

	if (ipsw_file_seek(file, oob_offset, SEEK_SET) < 0) {
		info("ERROR: Unable to seek to OOB offset 0x%" PRIx64 "\n", oob_offset);
		free(oob_data);
		return -1;
	}

	int64_t ir = ipsw_file_read(file, oob_data, oob_length);
	if (ir != (int64_t)oob_length) {
		info("ERROR: Unable to read OOB data from offset 0x%" PRIx64 ", expected %" PRIu64 ", got %" PRIi64 "\n",
		      oob_offset, oob_length, ir);
		free(oob_data);
		return -1;
	}

	if (asr_send_buffer(asr, oob_data, oob_length) < 0) {
		error("ERROR: Unable to send OOB data to ASR\n");
		free(oob_data);
		return -1;
	}

	free(oob_data);
	return 0;
}


int asr_send_payload(asr_client_t asr, ipsw_file_handle_t file)
{
	char *data = NULL;
	uint64_t i, length, bytes = 0;
	double progress = 0;

	length = ipsw_file_size(file);
	ipsw_file_seek(file, 0, SEEK_SET);

	data = (char*)malloc(ASR_PAYLOAD_CHUNK_SIZE + 20);

	SHA_CTX sha1;

	if (asr->checksum_chunks) {
		SHA1_Init(&sha1);
	}
	i = length;
	int retry = 5;
	int _is_retry = 0;
	while(i > 0 && retry >= 0) {
		uint32_t size = ASR_PAYLOAD_CHUNK_SIZE;
		uint32_t sendsize = 0;

		if (i < ASR_PAYLOAD_CHUNK_SIZE) {
			size = i;
		}
		if (_is_retry == 0) {
		if (ipsw_file_read(file, data, size) != (int64_t)size) {
			error("Error reading filesystem\n");
				return 0;
			}
		}

		sendsize = size;
		if (asr->checksum_chunks) {
			SHA1((unsigned char*)data, size, (unsigned char*)(data+size));
			sendsize += 20;
		}
		if (asr_send_buffer(asr, data, sendsize) < 0) {
			error("Unable to send filesystem payload chunk, retrying...\n");
			retry--;
			_is_retry = 1;
			continue;
		}
		_is_retry = 0;

		bytes += size;
		/*
		progress = ((double)bytes / (double)length);
		if (asr->progress_cb && ((int)(progress*100) > asr->lastprogress)) {
			asr->progress_cb(progress, asr->progress_cb_data);
			asr->lastprogress = (int)(progress*100);
		}
		*/
		i -= size;
	}

	free(data);
	return 0;
}



