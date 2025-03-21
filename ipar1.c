/*
 * idevicerestore.c
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ctype.h>
#include <getopt.h>
#include <plist/plist.h>
#include <zlib.h>
#include <libgen.h>
#include <signal.h>

#include <curl/curl.h>

#include <libimobiledevice-glue/sha.h>
#include <libimobiledevice-glue/utils.h>
#include <libtatsu/tss.h>

#include "ace3.h"
#include "dfu.h"
#include "img3.h"
#include "img4.h"
#include "ipsw.h"
#include "common.h"
#include "normal.h"
#include "restore.h"
#include "download.h"
#include "recovery.h"
#include "idevicerestore.h"

#include "limera1n.h"

#include "locking.h"

#define VERSION_XML "version.xml"

#ifndef IDEVICERESTORE_NOMAIN
static struct option longopts[] = {
	{ "ecid",           required_argument, NULL, 'i' },
	{ "udid",           required_argument, NULL, 'u' },
	{ "debug",          no_argument,       NULL, 'd' },
	{ "help",           no_argument,       NULL, 'h' },
	{ "erase",          no_argument,       NULL, 'e' },
	{ "custom",         no_argument,       NULL, 'c' },
	{ "latest",         no_argument,       NULL, 'l' },
	{ "server",         required_argument, NULL, 's' },
	{ "exclude",        no_argument,       NULL, 'x' },
	{ "shsh",           no_argument,       NULL, 't' },
	{ "keep-pers",      no_argument,       NULL, 'k' },
	{ "pwn",            no_argument,       NULL, 'p' },
	{ "no-action",      no_argument,       NULL, 'n' },
	{ "cache-path",     required_argument, NULL, 'C' },
	{ "no-input",       no_argument,       NULL, 'y' },
	{ "plain-progress", no_argument,       NULL, 'P' },
	{ "restore-mode",   no_argument,       NULL, 'R' },
	{ "ticket",         required_argument, NULL, 'T' },
	{ "no-restore",     no_argument,       NULL, 'z' },
	{ "version",        no_argument,       NULL, 'v' },
	{ "ipsw-info",      no_argument,       NULL, 'I' },
	{ "ignore-errors",  no_argument,       NULL,  1  },
	{ "variant",        required_argument, NULL,  2  },
	{ NULL, 0, NULL, 0 }
};


// 使用 C 的布尔类型
#include <stdbool.h>

// 定义全局变量用于存储密钥
static char g_decryption_key[256] = {0};
static bool g_key_set = false;  // 使用 C99 的 bool 类型

// 修改默认回调函数实现
static const char* decrypt_callback(void* user_data) {
    if (!g_key_set || strlen(g_decryption_key) == 0) {
        //printf("[decrypt_callback] No key set or key is empty\n");
        return NULL;
    }
    //printf("[decrypt_callback] Returning key: %s\n", g_decryption_key);
    return g_decryption_key;
}

// 密钥状态结构
struct decrypt_key_state {
    decrypt_key_callback_t key_callback;
    void* key_user_data;
};

// 初始化全局变量，使用 decrypt_callback
static struct decrypt_key_state decrypt_key_state = {
    .key_callback = decrypt_callback,
    .key_user_data = NULL
};


static void usage(int argc, char* argv[], int err)
{
	char* name = strrchr(argv[0], '/');
	fprintf((err) ? stderr : stdout,
	"Usage: %s [OPTIONS] PATH\n" \
	"\n" \
	"Restore IPSW firmware at PATH to an iOS device.\n" \
	"\n" \
	"PATH can be a compressed .ipsw file or a directory containing all files\n" \
	"extracted from an IPSW.\n" \
	"\n" \
	"OPTIONS:\n" \
	"  -i, --ecid ECID       Target specific device by its ECID\n" \
	"                        e.g. 0xaabb123456 (hex) or 1234567890 (decimal)\n" \
	"  -u, --udid UDID       Target specific device by its device UDID\n" \
	"                        NOTE: only works with devices in normal mode.\n" \
	"  -l, --latest          Use latest available firmware (with download on demand).\n" \
	"                        Before performing any action it will interactively ask\n" \
	"                        to select one of the currently signed firmware versions,\n" \
	"                        unless -y has been given too.\n" \
	"                        The PATH argument is ignored when using this option.\n" \
	"                        DO NOT USE if you need to preserve the baseband/unlock!\n" \
	"                        USE WITH CARE if you want to keep a jailbreakable\n" \
	"                        firmware!\n" \
	"  -e, --erase           Perform full restore instead of update, erasing all data\n" \
	"                        DO NOT USE if you want to preserve user data on the device!\n" \
	"  -y, --no-input        Non-interactive mode, do not ask for any input.\n" \
	"                        WARNING: This will disable certain checks/prompts that\n" \
	"                        are supposed to prevent DATA LOSS. Use with caution.\n" \
	"  -n, --no-action       Do not perform any restore action. If combined with -l\n" \
	"                        option the on-demand ipsw download is performed before\n" \
	"                        exiting.\n" \
	"  --ipsw-info           Print information about the IPSW at PATH and exit.\n" \
	"  -h, --help            Prints this usage information\n" \
	"  -C, --cache-path DIR  Use specified directory for caching extracted or other\n" \
	"                        reused files.\n" \
	"  -d, --debug           Enable communication debugging\n" \
	"  -v, --version         Print version information\n" \
	"\n" \
	"Advanced/experimental options:\n"
	"  -c, --custom          Restore with a custom firmware (requires bootrom exploit)\n" \
	"  -s, --server URL      Override default signing server request URL\n" \
	"  -x, --exclude         Exclude nor/baseband upgrade (legacy devices)\n" \
	"  -t, --shsh            Fetch TSS record and save to .shsh file, then exit\n" \
	"  -z, --no-restore      Do not restore and end after booting to the ramdisk\n" \
	"  -k, --keep-pers       Write personalized components to files for debugging\n" \
	"  -p, --pwn             Put device in pwned DFU mode and exit (limera1n devices)\n" \
	"  -P, --plain-progress  Print progress as plain step and progress\n" \
	"  -R, --restore-mode    Allow restoring from Restore mode\n" \
	"  -T, --ticket PATH     Use file at PATH to send as AP ticket\n" \
	"  --variant VARIANT     Use given VARIANT to match the build identity to use,\n" \
        "                        e.g. 'Customer Erase Install (IPSW)'\n" \
	"  --ignore-errors       Try to continue the restore process after certain\n" \
	"                        errors (like a failed baseband update)\n" \
	"                        WARNING: This might render the device unable to boot\n" \
	"                        or only partially functioning. Use with caution.\n" \
	"\n" \
	"Homepage:    <" PACKAGE_URL ">\n" \
	"Bug Reports: <" PACKAGE_BUGREPORT ">\n",
	(name ? name + 1 : argv[0]));
}
#endif

const uint8_t lpol_file[22] = {
		0x30, 0x14, 0x16, 0x04, 0x49, 0x4d, 0x34, 0x50,
		0x16, 0x04, 0x6c, 0x70, 0x6f, 0x6c, 0x16, 0x03,
		0x31, 0x2e, 0x30, 0x04, 0x01, 0x00
};
const uint32_t lpol_file_length = 22;

static int idevicerestore_keep_pers = 0;

static int load_version_data(struct idevicerestore_client_t* client)
{
	if (!client) {
		return -1;
	}

	struct stat fst;
	int cached = 0;

	char version_xml[1024];

	if (client->cache_dir) {
		if (stat(client->cache_dir, &fst) < 0) {
			mkdir_with_parents(client->cache_dir, 0755);
		}
		strcpy(version_xml, client->cache_dir);
		strcat(version_xml, "/");
		strcat(version_xml, VERSION_XML);
	} else {
		strcpy(version_xml, VERSION_XML);
	}

	if ((stat(version_xml, &fst) < 0) || ((time(NULL)-86400) > fst.st_mtime)) {
		char version_xml_tmp[1024];
		strcpy(version_xml_tmp, version_xml);
		strcat(version_xml_tmp, ".tmp");

		if (download_to_file("http://itunes.apple.com/check/version",  version_xml_tmp, 0) == 0) {
			remove(version_xml);
			if (rename(version_xml_tmp, version_xml) < 0) {
				error("ERROR: Could not update '%s'\n", version_xml);
			} else {
				info("NOTE: Updated version data.\n");
			}
			
		}
	} else {
		cached = 1;
	}

	char *verbuf = NULL;
	size_t verlen = 0;
	read_file(version_xml, (void**)&verbuf, &verlen);

	if (!verbuf) {
		error("ERROR: Could not load '%s'\n", version_xml);
		return -1;
	}

	client->version_data = NULL;
	plist_from_xml(verbuf, verlen, &client->version_data);
	free(verbuf);

	if (!client->version_data) {
		remove(version_xml);
		error("ERROR: Cannot parse plist data from '%s'.\n", version_xml);
		return -1;
	}

	if (cached) {
		info("NOTE: using cached version data\n");
	}

	return 0;
}

static int32_t get_version_num(const char *s_ver)
{
        int vers[3] = {0, 0, 0};
        if (sscanf(s_ver, "%d.%d.%d", &vers[0], &vers[1], &vers[2]) >= 2) {
                return ((vers[0] & 0xFF) << 16) | ((vers[1] & 0xFF) << 8) | (vers[2] & 0xFF);
        }
        return 0x00FFFFFF;
}

static int compare_versions(const char *s_ver1, const char *s_ver2)
{
	return (get_version_num(s_ver1) & 0xFFFF00) - (get_version_num(s_ver2) & 0xFFFF00);
}

static void idevice_event_cb(const idevice_event_t *event, void *userdata)
{
	struct idevicerestore_client_t *client = (struct idevicerestore_client_t*)userdata;
#ifdef HAVE_ENUM_IDEVICE_CONNECTION_TYPE
	if (event->conn_type != CONNECTION_USBMUXD) {
		// ignore everything but devices connected through USB
		return;
	}
#endif
	if (event->event == IDEVICE_DEVICE_ADD) {
		if (client->ignore_device_add_events) {
			return;
		}
		if (normal_check_mode(client) == 0) {
			mutex_lock(&client->device_event_mutex);
			client->mode = MODE_NORMAL;
			debug("%s: device %016" PRIx64 " (udid: %s) connected in normal mode\n", __func__, client->ecid, client->udid);
			cond_signal(&client->device_event_cond);
			mutex_unlock(&client->device_event_mutex);
		} else if (client->ecid && restore_check_mode(client) == 0) {
			mutex_lock(&client->device_event_mutex);
			client->mode = MODE_RESTORE;
			debug("%s: device %016" PRIx64 " (udid: %s) connected in restore mode\n", __func__, client->ecid, client->udid);
			cond_signal(&client->device_event_cond);
			mutex_unlock(&client->device_event_mutex);
		}
	} else if (event->event == IDEVICE_DEVICE_REMOVE) {
		if (client->udid && !strcmp(event->udid, client->udid)) {
			mutex_lock(&client->device_event_mutex);
			client->mode = MODE_UNKNOWN;
			debug("%s: device %016" PRIx64 " (udid: %s) disconnected\n", __func__, client->ecid, client->udid);
			client->ignore_device_add_events = 0;
			cond_signal(&client->device_event_cond);
			mutex_unlock(&client->device_event_mutex);
		}
	}
}

static void irecv_event_cb(const irecv_device_event_t* event, void *userdata)
{
	struct idevicerestore_client_t *client = (struct idevicerestore_client_t*)userdata;
	if (event->type == IRECV_DEVICE_ADD) {
		if (!client->udid && !client->ecid) {
			client->ecid = event->device_info->ecid;
		}
		if (client->ecid && event->device_info->ecid == client->ecid) {
			mutex_lock(&client->device_event_mutex);
			switch (event->mode) {
				case IRECV_K_WTF_MODE:
					client->mode = MODE_WTF;
					break;
				case IRECV_K_DFU_MODE:
					client->mode = MODE_DFU;
					break;
				case IRECV_K_PORT_DFU_MODE:
					client->mode = MODE_PORTDFU;
					break;
				case IRECV_K_RECOVERY_MODE_1:
				case IRECV_K_RECOVERY_MODE_2:
				case IRECV_K_RECOVERY_MODE_3:
				case IRECV_K_RECOVERY_MODE_4:
					client->mode = MODE_RECOVERY;
					break;
				default:
					client->mode = MODE_UNKNOWN;
			}
			debug("%s: device %016" PRIx64 " (udid: %s) connected in %s mode\n", __func__, client->ecid, (client->udid) ? client->udid : "N/A", client->mode->string);
			cond_signal(&client->device_event_cond);
			mutex_unlock(&client->device_event_mutex);
		}
	} else if (event->type == IRECV_DEVICE_REMOVE) {
		if (client->ecid && event->device_info->ecid == client->ecid) {
			mutex_lock(&client->device_event_mutex);
			client->mode = MODE_UNKNOWN;
			debug("%s: device %016" PRIx64 " (udid: %s) disconnected\n", __func__, client->ecid, (client->udid) ? client->udid : "N/A");
			if (event->mode == IRECV_K_PORT_DFU_MODE) {
				// We have to reset the ECID here if a port DFU device disconnects,
				// because when the device reconnects in a different mode, it will
				// have the actual device ECID and wouldn't get detected.
				client->ecid = 0;
			}
			cond_signal(&client->device_event_cond);
			mutex_unlock(&client->device_event_mutex);
		}
	}
}



// 实现设置密钥回调的函数
int idevicerestore_set_decryption_key_callback(decrypt_key_callback_t callback, void* user_data) {
    if (callback) {
        decrypt_key_state.key_callback = callback;
        decrypt_key_state.key_user_data = user_data;
    } else {
        decrypt_key_state.key_callback = decrypt_callback;
        decrypt_key_state.key_user_data = NULL;
    }
    return 0;
}

//获取密钥的内部辅助函数
const char* idevicerestore_get_decryption_key(void) {
    if (decrypt_key_state.key_callback) {
        const char* key = decrypt_key_state.key_callback(decrypt_key_state.key_user_data);
        return key;
    }
    return NULL;
}


int build_identity_check_components_in_ipsw(plist_t build_identity, ipsw_archive_t ipsw);

int idevicerestore_start(struct idevicerestore_client_t* client)
{
	int tss_enabled = 0;
	int result = 0;

	if (!client) {
		return -1;
	}

	if ((client->flags & FLAG_LATEST) && (client->flags & FLAG_CUSTOM)) {
		error("ERROR: FLAG_LATEST cannot be used with FLAG_CUSTOM.\n");
		return -1;
	}

	if (!client->ipsw && !(client->flags & FLAG_PWN) && !(client->flags & FLAG_LATEST)) {
		error("ERROR: no ipsw file given\n");
		return -1;
	}

	if (client->debug_level > 0) {
		idevicerestore_debug = 1;
		if (client->debug_level > 1) {
			irecv_set_debug_level(1);
		}
		if (client->debug_level > 2) {
			idevice_set_debug_level(1);
		}
		tss_set_debug_level(client->debug_level);
	}

	idevicerestore_progress(client, RESTORE_STEP_DETECT, 0.0);

	irecv_device_event_subscribe(&client->irecv_e_ctx, irecv_event_cb, client);

	idevice_event_subscribe(idevice_event_cb, client);
	client->idevice_e_ctx = idevice_event_cb;

	// check which mode the device is currently in so we know where to start
	mutex_lock(&client->device_event_mutex);
	if (client->mode == MODE_UNKNOWN) {
		cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 10000);
		if (client->mode == MODE_UNKNOWN || (client->flags & FLAG_QUIT)) {
			mutex_unlock(&client->device_event_mutex);
			error("ERROR: Unable to discover device mode. Please make sure a device is attached.\n");
			return -1;
		}
	}
	idevicerestore_progress(client, RESTORE_STEP_DETECT, 0.1);
	info("Found device in %s mode\n", client->mode->string);
	mutex_unlock(&client->device_event_mutex);

	if (client->mode == MODE_WTF) {
		unsigned int cpid = 0;

		if (dfu_client_new(client) != 0) {
			error("ERROR: Could not open device in WTF mode\n");
			return -1;
		}
		if ((dfu_get_cpid(client, &cpid) < 0) || (cpid == 0)) {
			error("ERROR: Could not get CPID for WTF mode device\n");
			dfu_client_free(client);
			return -1;
		}

		char wtfname[256];
		snprintf(wtfname, sizeof(wtfname), "Firmware/dfu/WTF.s5l%04xxall.RELEASE.dfu", cpid);
		unsigned char* wtftmp = NULL;
		unsigned int wtfsize = 0;

		// Prefer to get WTF file from the restore IPSW
		ipsw_extract_to_memory(client->ipsw, wtfname, &wtftmp, &wtfsize);
		if (!wtftmp) {
			// update version data (from cache, or apple if too old)
			load_version_data(client);

			// Download WTF IPSW
			char* s_wtfurl = NULL;
			plist_t wtfurl = plist_access_path(client->version_data, 7, "MobileDeviceSoftwareVersionsByVersion", "5", "RecoverySoftwareVersions", "WTF", "304218112", "5", "FirmwareURL");
			if (wtfurl && (plist_get_node_type(wtfurl) == PLIST_STRING)) {
				plist_get_string_val(wtfurl, &s_wtfurl);
			}
			if (!s_wtfurl) {
				info("Using hardcoded x12220000_5_Recovery.ipsw URL\n");
				s_wtfurl = strdup("http://appldnld.apple.com.edgesuite.net/content.info.apple.com/iPhone/061-6618.20090617.Xse7Y/x12220000_5_Recovery.ipsw");
			}

			// make a local file name
			char* fnpart = strrchr(s_wtfurl, '/');
			if (!fnpart) {
				fnpart = (char*)"x12220000_5_Recovery.ipsw";
			} else {
				fnpart++;
			}
			struct stat fst;
			char wtfipsw[1024];
			if (client->cache_dir) {
				if (stat(client->cache_dir, &fst) < 0) {
					mkdir_with_parents(client->cache_dir, 0755);
				}
				strcpy(wtfipsw, client->cache_dir);
				strcat(wtfipsw, "/");
				strcat(wtfipsw, fnpart);
			} else {
				strcpy(wtfipsw, fnpart);
			}
			if (stat(wtfipsw, &fst) != 0) {
				download_to_file(s_wtfurl, wtfipsw, 0);
			}

			ipsw_archive_t wtf_ipsw = ipsw_open(wtfipsw);
			ipsw_extract_to_memory(wtf_ipsw, wtfname, &wtftmp, &wtfsize);
			ipsw_close(wtf_ipsw);
			if (!wtftmp) {
				error("ERROR: Could not extract WTF\n");
			}
		}

		mutex_lock(&client->device_event_mutex);
		if (wtftmp) {
			if (dfu_send_buffer(client, wtftmp, wtfsize) != 0) {
				error("ERROR: Could not send WTF...\n");
			}
		}
		dfu_client_free(client);

		free(wtftmp);

		cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 10000);
		if (client->mode != MODE_DFU || (client->flags & FLAG_QUIT)) {
			mutex_unlock(&client->device_event_mutex);
			/* TODO: verify if it actually goes from 0x1222 -> 0x1227 */
			error("ERROR: Failed to put device into DFU from WTF mode\n");
			return -1;
		}
		mutex_unlock(&client->device_event_mutex);
	}

	// discover the device type
	client->device = get_irecv_device(client);
	if (client->device == NULL) {
		error("ERROR: Unable to discover device type\n");
		return -1;
	}
	if (client->ecid == 0) {
		error("ERROR: Unable to determine ECID\n");
		return -1;
	}
	info("ECID: %" PRIu64 "\n", client->ecid);

	idevicerestore_progress(client, RESTORE_STEP_DETECT, 0.2);
	info("Identified device as %s, %s\n", client->device->hardware_model, client->device->product_type);

	if ((client->flags & FLAG_PWN) && (client->mode != MODE_DFU)) {
		error("ERROR: you need to put your device into DFU mode to pwn it.\n");
		return -1;
	}

	if (client->mode == MODE_NORMAL) {
		plist_t pver = normal_get_lockdown_value(client, NULL, "ProductVersion");
		if (pver) {
			plist_get_string_val(pver, &client->device_version);
			plist_free(pver);
		}
		pver = normal_get_lockdown_value(client, NULL, "BuildVersion");
		if (pver) {
			plist_get_string_val(pver, &client->device_build);
			plist_free(pver);
		}
	}
	info("Device Product Version: %s\n", (client->device_version) ? client->device_version : "N/A");
	info("Device Product Build: %s\n", (client->device_build) ? client->device_build : "N/A");

	if (client->flags & FLAG_PWN) {
		recovery_client_free(client);

		if (client->mode != MODE_DFU) {
			error("ERROR: Device needs to be in DFU mode for this option.\n");
			return -1;
		}

		info("connecting to DFU\n");
		if (dfu_client_new(client) < 0) {
			return -1;
		}

		if (limera1n_is_supported(client->device)) {
			info("exploiting with limera1n...\n");
			if (limera1n_exploit(client->device, &client->dfu->client) != 0) {
				error("ERROR: limera1n exploit failed\n");
				dfu_client_free(client);
				return -1;
			}
			dfu_client_free(client);
			info("Device should be in pwned DFU state now.\n");

			return 0;
		}
		else {
			dfu_client_free(client);
			error("ERROR: This device is not supported by the limera1n exploit");
			return -1;
		}
	}

	if (client->flags & FLAG_LATEST) {
		char *fwurl = NULL;
		unsigned char fwsha1[20];
		unsigned char *p_fwsha1 = NULL;
		plist_t signed_fws = NULL;
		int res = ipsw_get_signed_firmwares(client->device->product_type, &signed_fws);
		if (res < 0) {
			error("ERROR: Could not fetch list of signed firmwares.\n");
			return res;
		}
		uint32_t count = plist_array_get_size(signed_fws);
		if (count == 0) {
			plist_free(signed_fws);
			error("ERROR: No firmwares are currently being signed for %s (REALLY?!)\n", client->device->product_type);
			return -1;
		}
		plist_t selected_fw = NULL;
		if (client->flags & FLAG_INTERACTIVE) {
			uint32_t i = 0;
			info("The following firmwares are currently being signed for %s:\n", client->device->product_type);
			for (i = 0; i < count; i++) {
				plist_t fw = plist_array_get_item(signed_fws, i);
				plist_t p_version = plist_dict_get_item(fw, "version");
				plist_t p_build = plist_dict_get_item(fw, "buildid");
				char *s_version = NULL;
				char *s_build = NULL;
				plist_get_string_val(p_version, &s_version);
				plist_get_string_val(p_build, &s_build);
				info("  [%d] %s (build %s)\n", i+1, s_version, s_build);
				free(s_version);
				free(s_build);
			}
			while (1) {
				char input[64];
				printf("Select the firmware you want to restore: ");
				fflush(stdout);
				fflush(stdin);
				get_user_input(input, 63, 0);
				if (*input == '\0') {
					plist_free(signed_fws);
					return -1;
				}
				if (client->flags & FLAG_QUIT) {
					return -1;
				}
				unsigned long selected = strtoul(input, NULL, 10);
				if (selected == 0 || selected > count) {
					printf("Invalid input value. Must be in range: 1..%u\n", count);
					continue;
				}
				selected_fw = plist_array_get_item(signed_fws, (uint32_t)selected-1);
				break;
			}
		} else {
			info("NOTE: Running non-interactively, automatically selecting latest available version\n");
			selected_fw = plist_array_get_item(signed_fws, 0);
		}
		if (!selected_fw) {
			error("ERROR: failed to select latest firmware?!\n");
			plist_free(signed_fws);
			return -1;
		} else {
			plist_t p_version = plist_dict_get_item(selected_fw, "version");
			plist_t p_build = plist_dict_get_item(selected_fw, "buildid");
			char *s_version = NULL;
			char *s_build = NULL;
			plist_get_string_val(p_version, &s_version);
			plist_get_string_val(p_build, &s_build);
			info("Selected firmware %s (build %s)\n", s_version, s_build);
			free(s_version);
			free(s_build);
			plist_t p_url = plist_dict_get_item(selected_fw, "url");
			plist_t p_sha1 = plist_dict_get_item(selected_fw, "sha1sum");
			char *s_sha1 = NULL;
			plist_get_string_val(p_url, &fwurl);
			plist_get_string_val(p_sha1, &s_sha1);
			if (strlen(s_sha1) == 40) {
				int i;
				int v;
				for (i = 0; i < 40; i+=2) {
					v = 0;
					sscanf(s_sha1+i, "%02x", &v);
					fwsha1[i/2] = (unsigned char)v;
				}
				p_fwsha1 = &fwsha1[0];
			} else {
				error("ERROR: unexpected size of sha1sum\n");
			}
		}
		plist_free(signed_fws);

		if (!fwurl || !p_fwsha1) {
			error("ERROR: Missing firmware URL or SHA1\n");
			return -1;
		}

		char* ipsw = NULL;
		res = ipsw_download_fw(fwurl, p_fwsha1, client->cache_dir, &ipsw);
		if (res != 0) {
			free(ipsw);
			return res;
		} else {
			client->ipsw = ipsw_open(ipsw);
			if (!client->ipsw) {
				error("ERROR: Failed to open ipsw '%s'\n", ipsw);
				free(ipsw);
				return -1;
			}
			free(ipsw);
		}
	}
	idevicerestore_progress(client, RESTORE_STEP_DETECT, 0.6);

	if (client->flags & FLAG_NOACTION) {
		return 0;
	}

	// extract buildmanifest
	if (client->flags & FLAG_CUSTOM) {
		info("Extracting Restore.plist from IPSW\n");
		if (ipsw_extract_restore_plist(client->ipsw, &client->build_manifest) < 0) {
			error("ERROR: Unable to extract Restore.plist from %s. Firmware file might be corrupt.\n", client->ipsw->path);
			return -1;
		}
	} else {
		info("Extracting BuildManifest from IPSW\n");
		if (ipsw_extract_build_manifest(client->ipsw, &client->build_manifest, &tss_enabled) < 0) {
			error("ERROR: Unable to extract BuildManifest from %s. Firmware file might be corrupt.\n", client->ipsw->path);
			return -1;
		}
	}

	if (client->flags & FLAG_CUSTOM) {
		// prevent attempt to sign custom firmware
		tss_enabled = 0;
		info("Custom firmware requested; TSS has been disabled.\n");
	}

	if (client->mode == MODE_RESTORE) {
		if (!(client->flags & FLAG_ALLOW_RESTORE_MODE)) {
			if (restore_reboot(client) < 0) {
				error("ERROR: Unable to exit restore mode\n");
				return -2;
			}

			// we need to refresh the current mode again
			mutex_lock(&client->device_event_mutex);
			cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 60000);
			if (client->mode == MODE_UNKNOWN || (client->flags & FLAG_QUIT)) {
				mutex_unlock(&client->device_event_mutex);
				error("ERROR: Unable to discover device mode. Please make sure a device is attached.\n");
				return -1;
			}
			info("Found device in %s mode\n", client->mode->string);
			mutex_unlock(&client->device_event_mutex);
		}
	}

	if (client->mode == MODE_PORTDFU) {
		unsigned int pdfu_bdid = 0;
		unsigned int pdfu_cpid = 0;
		unsigned int prev = 0;

		if (dfu_get_bdid(client, &pdfu_bdid) < 0) {
			error("ERROR: Failed to get bdid for Port DFU device!\n");
			return -1;
		}
		if (dfu_get_cpid(client, &pdfu_cpid) < 0) {
			error("ERROR: Failed to get cpid for Port DFU device!\n");
			return -1;
		}
		if (dfu_get_prev(client, &prev) < 0) {
			error("ERROR: Failed to get PREV for Port DFU device!\n");
			return -1;
		}

		unsigned char* pdfu_nonce = NULL;
		unsigned int pdfu_nsize = 0;
		if (dfu_get_portdfu_nonce(client, &pdfu_nonce, &pdfu_nsize) < 0) {
			error("ERROR: Failed to get nonce for Port DFU device!\n");
			return -1;
		}

		plist_t build_identity = build_manifest_get_build_identity_for_model_with_variant(client->build_manifest, client->device->hardware_model, RESTORE_VARIANT_ERASE_INSTALL, 0);
		if (!build_identity) {
			error("ERORR: Failed to get build identity\n");
			return -1;
		}

		unsigned int b_pdfu_cpid = (unsigned int)plist_dict_get_uint(build_identity, "USBPortController1,ChipID");
		if (b_pdfu_cpid != pdfu_cpid) {
			error("ERROR: cpid 0x%02x doesn't match USBPortController1,ChipID in build identity (0x%02x)\n", pdfu_cpid, b_pdfu_cpid);
			return -1;
		}
		unsigned int b_pdfu_bdid = (unsigned int)plist_dict_get_uint(build_identity, "USBPortController1,BoardID");
		if (b_pdfu_bdid != pdfu_bdid) {
			error("ERROR: bdid 0x%x doesn't match USBPortController1,BoardID in build identity (0x%x)\n", pdfu_bdid, b_pdfu_bdid);
			return -1;
		}

		plist_t parameters = plist_new_dict();
		plist_dict_set_item(parameters, "@USBPortController1,Ticket", plist_new_bool(1));
		plist_dict_set_item(parameters, "USBPortController1,ECID", plist_new_int(client->ecid));
		plist_dict_copy_item(parameters, build_identity, "USBPortController1,BoardID", NULL);
		plist_dict_copy_item(parameters, build_identity, "USBPortController1,ChipID", NULL);
		plist_dict_copy_item(parameters, build_identity, "USBPortController1,SecurityDomain", NULL);
		plist_dict_set_item(parameters, "USBPortController1,SecurityMode", plist_new_bool(1));
		plist_dict_set_item(parameters, "USBPortController1,ProductionMode", plist_new_bool(1));
		plist_t usbf = plist_access_path(build_identity, 2, "Manifest", "USBPortController1,USBFirmware");
		if (!usbf) {
			plist_free(parameters);
			error("ERROR: Unable to find USBPortController1,USBFirmware in build identity\n");
			return -1;
		}
		plist_t p_fwpath = plist_access_path(usbf, 2, "Info", "Path");
		if (!p_fwpath) {
			plist_free(parameters);
			error("ERROR: Unable to find path of USBPortController1,USBFirmware component\n");
			return -1;
		}
		const char* fwpath = plist_get_string_ptr(p_fwpath, NULL);
		if (!fwpath) {
			plist_free(parameters);
			error("ERROR: Unable to get path of USBPortController1,USBFirmware component\n");
			return -1;
		}
		unsigned char* uarp_buf = NULL;
		unsigned int uarp_size = 0;
		if (ipsw_extract_to_memory(client->ipsw, fwpath, &uarp_buf, &uarp_size) < 0) {
			plist_free(parameters);
			error("ERROR: Unable to extract '%s' from IPSW\n", fwpath);
			return -1;
		}
		usbf = plist_copy(usbf);
		plist_dict_remove_item(usbf, "Info");
		plist_dict_set_item(parameters, "USBPortController1,USBFirmware", usbf);
		plist_dict_set_item(parameters, "USBPortController1,Nonce", plist_new_data((const char*)pdfu_nonce, pdfu_nsize));

		plist_t request = tss_request_new(NULL);
		if (request == NULL) {
			plist_free(parameters);
			error("ERROR: Unable to create TSS request\n");
			return -1;
		}
		plist_dict_merge(&request, parameters);
		plist_free(parameters);

		// send request and grab response
		plist_t response = tss_request_send(request, client->tss_url);
		plist_free(request);
		if (response == NULL) {
			error("ERROR: Unable to send TSS request 1\n");
			return -1;
		}
		info("Received USBPortController1,Ticket\n");

		info("Creating Ace3Binary\n");
		unsigned char* ace3bin = NULL;
		size_t ace3bin_size = 0;
		if (ace3_create_binary(uarp_buf, uarp_size, pdfu_bdid, prev, response, &ace3bin, &ace3bin_size) < 0) {
			error("ERROR: Could not create Ace3Binary\n");
			return -1;
		}
		plist_free(response);
		free(uarp_buf);

		if (idevicerestore_keep_pers) {
			write_file("Ace3Binary", (const char*)ace3bin, ace3bin_size);
		}

		if (dfu_send_buffer_with_options(client, ace3bin, ace3bin_size, IRECV_SEND_OPT_DFU_NOTIFY_FINISH | IRECV_SEND_OPT_DFU_SMALL_PKT) < 0) {
			error("ERROR: Could not send Ace3Buffer to device\n");
			return -1;
		}

		debug("Waiting for device to disconnect...\n");
		cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 5000);
		if (client->mode != MODE_UNKNOWN || (client->flags & FLAG_QUIT)) {
			mutex_unlock(&client->device_event_mutex);

			if (!(client->flags & FLAG_QUIT)) {
				error("ERROR: Device did not disconnect. Port DFU failed.\n");
			}
			return -2;
		}
		dfu_client_free(client);
		debug("Waiting for device to reconnect in DFU mode...\n");
		cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 20000);
		if (client->mode != MODE_DFU || (client->flags & FLAG_QUIT)) {
			mutex_unlock(&client->device_event_mutex);
			if (!(client->flags & FLAG_QUIT)) {
				error("ERROR: Device did not reconnect in DFU mode. Port DFU failed.\n");
			}
			return -2;
		}
		mutex_unlock(&client->device_event_mutex);

		if (client->flags & FLAG_NOACTION) {
			info("Port DFU restore successful.\n");
			return 0;
		} else {
			info("Port DFU restore successful. Continuing.\n");
		}
	}

	idevicerestore_progress(client, RESTORE_STEP_DETECT, 0.8);

	/* check if device type is supported by the given build manifest */
	if (build_manifest_check_compatibility(client->build_manifest, client->device->product_type) < 0) {
		error("ERROR: Could not make sure this firmware is suitable for the current device. Refusing to continue.\n");
		return -1;
	}

	/* print iOS information from the manifest */
	build_manifest_get_version_information(client->build_manifest, client);

	info("IPSW Product Version: %s\n", client->version);
	info("IPSW Product Build: %s Major: %d\n", client->build, client->build_major);

	client->image4supported = is_image4_supported(client);
	info("Device supports Image4: %s\n", (client->image4supported) ? "true" : "false");

	// choose whether this is an upgrade or a restore (default to upgrade)
	client->tss = NULL;
	plist_t build_identity = NULL;
	int build_identity_needs_free = 0;
	if (client->flags & FLAG_CUSTOM) {
		build_identity = plist_new_dict();
		build_identity_needs_free = 1;
		{
			plist_t node;
			plist_t comp;
			plist_t inf;
			plist_t manifest;

			char tmpstr[256];
			char p_all_flash[128];
			char lcmodel[8];
			strcpy(lcmodel, client->device->hardware_model);
			int x = 0;
			while (lcmodel[x]) {
				lcmodel[x] = tolower(lcmodel[x]);
				x++;
			}

			snprintf(p_all_flash, sizeof(p_all_flash), "Firmware/all_flash/all_flash.%s.%s", lcmodel, "production");
			strcpy(tmpstr, p_all_flash);
			strcat(tmpstr, "/manifest");

			// get all_flash file manifest
			char *files[16];
			char *fmanifest = NULL;
			uint32_t msize = 0;
			if (ipsw_extract_to_memory(client->ipsw, tmpstr, (unsigned char**)&fmanifest, &msize) < 0) {
				error("ERROR: could not extract %s from IPSW\n", tmpstr);
				free(build_identity);
				return -1;
			}

			char *tok = strtok(fmanifest, "\r\n");
			int fc = 0;
			while (tok) {
				files[fc++] = strdup(tok);
				if (fc >= 16) {
					break;
				}
				tok = strtok(NULL, "\r\n");
			}
			free(fmanifest);

			manifest = plist_new_dict();

			for (x = 0; x < fc; x++) {
				inf = plist_new_dict();
				strcpy(tmpstr, p_all_flash);
				strcat(tmpstr, "/");
				strcat(tmpstr, files[x]);
				plist_dict_set_item(inf, "Path", plist_new_string(tmpstr));
				comp = plist_new_dict();
				plist_dict_set_item(comp, "Info", inf);
				const char* compname = get_component_name(files[x]);
				if (compname) {
					plist_dict_set_item(manifest, compname, comp);
					if (!strncmp(files[x], "DeviceTree", 10)) {
						plist_dict_set_item(manifest, "RestoreDeviceTree", plist_copy(comp));
					}
				} else {
					error("WARNING: unhandled component %s\n", files[x]);
					plist_free(comp);
				}
				free(files[x]);
				files[x] = NULL;
			}

			// add iBSS
			snprintf(tmpstr, sizeof(tmpstr), "Firmware/dfu/iBSS.%s.%s.dfu", lcmodel, "RELEASE");
			inf = plist_new_dict();
			plist_dict_set_item(inf, "Path", plist_new_string(tmpstr));
			comp = plist_new_dict();
			plist_dict_set_item(comp, "Info", inf);
			plist_dict_set_item(manifest, "iBSS", comp);

			// add iBEC
			snprintf(tmpstr, sizeof(tmpstr), "Firmware/dfu/iBEC.%s.%s.dfu", lcmodel, "RELEASE");
			inf = plist_new_dict();
			plist_dict_set_item(inf, "Path", plist_new_string(tmpstr));
			comp = plist_new_dict();
			plist_dict_set_item(comp, "Info", inf);
			plist_dict_set_item(manifest, "iBEC", comp);

			// add kernel cache
			plist_t kdict = NULL;

			node = plist_dict_get_item(client->build_manifest, "KernelCachesByTarget");
			if (node && (plist_get_node_type(node) == PLIST_DICT)) {
				char tt[4];
				strncpy(tt, lcmodel, 3);
				tt[3] = 0;
				kdict = plist_dict_get_item(node, tt);
			} else {
				// Populated in older iOS IPSWs
				kdict = plist_dict_get_item(client->build_manifest, "RestoreKernelCaches");
			}
			if (kdict && (plist_get_node_type(kdict) == PLIST_DICT)) {
				plist_t kc = plist_dict_get_item(kdict, "Release");
				if (kc && (plist_get_node_type(kc) == PLIST_STRING)) {
					inf = plist_new_dict();
					plist_dict_set_item(inf, "Path", plist_copy(kc));
					comp = plist_new_dict();
					plist_dict_set_item(comp, "Info", inf);
					plist_dict_set_item(manifest, "KernelCache", comp);
					plist_dict_set_item(manifest, "RestoreKernelCache", plist_copy(comp));
				}
			}

			// add ramdisk
			node = plist_dict_get_item(client->build_manifest, "RestoreRamDisks");
			if (node && (plist_get_node_type(node) == PLIST_DICT)) {
				plist_t rd = plist_dict_get_item(node, (client->flags & FLAG_ERASE) ? "User" : "Update");
				// if no "Update" ram disk entry is found try "User" ram disk instead
				if (!rd && !(client->flags & FLAG_ERASE)) {
					rd = plist_dict_get_item(node, "User");
					// also, set the ERASE flag since we actually change the restore variant
					client->flags |= FLAG_ERASE;
				}
				if (rd && (plist_get_node_type(rd) == PLIST_STRING)) {
					inf = plist_new_dict();
					plist_dict_set_item(inf, "Path", plist_copy(rd));
					comp = plist_new_dict();
					plist_dict_set_item(comp, "Info", inf);
					plist_dict_set_item(manifest, "RestoreRamDisk", comp);
				}
			}

			// add OS filesystem
			node = plist_dict_get_item(client->build_manifest, "SystemRestoreImages");
			if (!node) {
				error("ERROR: missing SystemRestoreImages in Restore.plist\n");
			}
			plist_t os = plist_dict_get_item(node, "User");
			if (!os) {
				error("ERROR: missing filesystem in Restore.plist\n");
			} else {
				inf = plist_new_dict();
				plist_dict_set_item(inf, "Path", plist_copy(os));
				comp = plist_new_dict();
				plist_dict_set_item(comp, "Info", inf);
				plist_dict_set_item(manifest, "OS", comp);
			}

			// add info
			inf = plist_new_dict();
			plist_dict_set_item(inf, "RestoreBehavior", plist_new_string((client->flags & FLAG_ERASE) ? "Erase" : "Update"));
			plist_dict_set_item(inf, "Variant", plist_new_string((client->flags & FLAG_ERASE) ? "Customer " RESTORE_VARIANT_ERASE_INSTALL : "Customer " RESTORE_VARIANT_UPGRADE_INSTALL));
			plist_dict_set_item(build_identity, "Info", inf);

			// finally add manifest
			plist_dict_set_item(build_identity, "Manifest", manifest);
		}
	} else if (client->restore_variant) {
		build_identity = build_manifest_get_build_identity_for_model_with_variant(client->build_manifest, client->device->hardware_model, client->restore_variant, 1);
	} else if (client->flags & FLAG_ERASE) {
		build_identity = build_manifest_get_build_identity_for_model_with_variant(client->build_manifest, client->device->hardware_model, RESTORE_VARIANT_ERASE_INSTALL, 0);
	} else {
		build_identity = build_manifest_get_build_identity_for_model_with_variant(client->build_manifest, client->device->hardware_model, RESTORE_VARIANT_UPGRADE_INSTALL, 0);
		if (!build_identity) {
			build_identity = build_manifest_get_build_identity_for_model(client->build_manifest, client->device->hardware_model);
		}
	}
	if (build_identity == NULL) {
		error("ERROR: Unable to find a matching build identity\n");
		return -1;
	}

	client->macos_variant = build_manifest_get_build_identity_for_model_with_variant(client->build_manifest, client->device->hardware_model, RESTORE_VARIANT_MACOS_RECOVERY_OS, 1);

	/* print information about current build identity */
	build_identity_print_information(build_identity);

	if (client->macos_variant) {
		info("Performing macOS restore\n");
	}

	if (client->mode == MODE_NORMAL && !(client->flags & FLAG_ERASE) && !(client->flags & FLAG_SHSHONLY)) {
		if (client->device_version && (compare_versions(client->device_version, client->version) > 0)) {
			if (client->flags & FLAG_INTERACTIVE) {
				char input[64];
				char spaces[16];
				int num_spaces = 13 - strlen(client->version) - strlen(client->device_version);
				memset(spaces, ' ', num_spaces);
				spaces[num_spaces] = '\0';
				printf("################################ [ WARNING ] #################################\n"
				       "# You are trying to DOWNGRADE a %s device with an IPSW for %s while%s #\n"
				       "# trying to preserve the user data (Upgrade restore). This *might* work, but #\n"
				       "# there is a VERY HIGH chance it might FAIL BADLY with COMPLETE DATA LOSS.   #\n"
				       "# Hit CTRL+C now if you want to abort the restore.                           #\n"
				       "# If you want to take the risk (and have a backup of your important data!)   #\n"
				       "# type YES and press ENTER to continue. You have been warned.                #\n"
				       "##############################################################################\n",
				       client->device_version, client->version, spaces);
				while (1) {
					printf("> ");
					fflush(stdout);
					fflush(stdin);
					input[0] = '\0';
					get_user_input(input, 63, 0);
					if (client->flags & FLAG_QUIT) {
						return -1;
					}
					if (*input != '\0' && !strcmp(input, "YES")) {
						break;
					} else {
						printf("Invalid input. Please type YES or hit CTRL+C to abort.\n");
						continue;
					}
				}
			}
		}
	}

	if (client->flags & FLAG_ERASE && client->flags & FLAG_INTERACTIVE) {
		char input[64];
		printf("################################ [ WARNING ] #################################\n"
		       "# You are about to perform an *ERASE* restore. ALL DATA on the target device #\n"
		       "# will be IRREVERSIBLY DESTROYED. If you want to update your device without  #\n"
		       "# erasing the user data, hit CTRL+C now and restart without -e or --erase    #\n"
		       "# command line switch.                                                       #\n"
		       "# If you want to continue with the ERASE, please type YES and press ENTER.   #\n"
		       "##############################################################################\n");
		while (1) {
			printf("> ");
			fflush(stdout);
			fflush(stdin);
			input[0] = '\0';
			get_user_input(input, 63, 0);
			if (client->flags & FLAG_QUIT) {
				return -1;
			}
			if (*input != '\0' && !strcmp(input, "YES")) {
				break;
			} else {
				printf("Invalid input. Please type YES or hit CTRL+C to abort.\n");
				continue;
			}
		}
	}

	idevicerestore_progress(client, RESTORE_STEP_PREPARE, 0.0);

	/* check if all components we need are actually there */
	info("Checking IPSW for required components...\n");
	if (build_identity_check_components_in_ipsw(build_identity, client->ipsw) < 0) {
		error("ERROR: Could not find all required components in IPSW %s\n", client->ipsw->path);
		return -1;
	}
	info("All required components found in IPSW\n");

	/* Get OS (filesystem) name from build identity */
	char* os_path = NULL;
	if (build_identity_get_component_path(build_identity, "OS", &os_path) < 0) {
		error("ERROR: Unable to get path for filesystem component\n");
		return -1;
	}

	/* check if IPSW has OS component 'stored' in ZIP archive, otherwise we need to extract it */
	int needs_os_extraction = 0;
	if (client->ipsw->zip) {
		ipsw_file_handle_t zfile = ipsw_file_open(client->ipsw, os_path);
		if (zfile) {
			if (!zfile->seekable) {
				needs_os_extraction = 1;
			}
			ipsw_file_close(zfile);
		}
	}

	if (needs_os_extraction && !(client->flags & FLAG_SHSHONLY)) {
		char* tmpf = NULL;
		struct stat st;
		if (client->cache_dir) {
			memset(&st, '\0', sizeof(struct stat));
			if (stat(client->cache_dir, &st) < 0) {
				mkdir_with_parents(client->cache_dir, 0755);
			}
			char* ipsw_basename = strdup(path_get_basename(client->ipsw->path));
			char* p = strrchr(ipsw_basename, '.');
			if (p && isalpha(*(p+1))) {
				*p = '\0';
			}
			tmpf = string_build_path(client->cache_dir, ipsw_basename, NULL);
			mkdir_with_parents(tmpf, 0755);
			free(tmpf);
			tmpf = string_build_path(client->cache_dir, ipsw_basename, os_path, NULL);
			free(ipsw_basename);
		} else {
			tmpf = get_temp_filename(NULL);
			client->delete_fs = 1;
		}

		/* check if we already have it extracted */
		uint64_t fssize = 0;
		ipsw_get_file_size(client->ipsw, os_path, &fssize);
		memset(&st, '\0', sizeof(struct stat));
		if (stat(tmpf, &st) == 0) {
			if ((fssize > 0) && ((uint64_t)st.st_size == fssize)) {
				info("Using cached filesystem from '%s'\n", tmpf);
				client->filesystem = tmpf;
			}
		}

		if (!client->filesystem) {
			info("Extracting filesystem from IPSW: %s\n", os_path);
			if (ipsw_extract_to_file_with_progress(client->ipsw, os_path, tmpf, 1) < 0) {
				error("ERROR: Unable to extract filesystem from IPSW\n");
				info("Removing %s\n", tmpf);
				unlink(tmpf);
				free(tmpf);
				return -1;
			}
			client->filesystem = tmpf;
		}
	}

	idevicerestore_progress(client, RESTORE_STEP_PREPARE, 0.2);

	/* retrieve shsh blobs if required */
	if (tss_enabled) {
		int stashbag_commit_required = 0;

		if (client->mode == MODE_NORMAL && !(client->flags & FLAG_ERASE) && !(client->flags & FLAG_SHSHONLY)) {
			plist_t node = normal_get_lockdown_value(client, NULL, "HasSiDP");
			uint8_t needs_preboard = 0;
			if (node && plist_get_node_type(node) == PLIST_BOOLEAN) {
				plist_get_bool_val(node, &needs_preboard);
			}
			if (needs_preboard) {
				info("Checking if device requires stashbag...\n");
				plist_t manifest;
				if (get_preboard_manifest(client, build_identity, &manifest) < 0) {
					error("ERROR: Unable to create preboard manifest.\n");
					return -1;
				}
				debug("DEBUG: creating stashbag...\n");
				int err = normal_handle_create_stashbag(client, manifest);
				if (err < 0) {
					if (err == -2) {
						error("ERROR: Could not create stashbag (timeout).\n");
					} else {
						error("ERROR: An error occurred while creating the stashbag.\n");
					}
					return -1;
				} else if (err == 1) {
					stashbag_commit_required = 1;
				}
				plist_free(manifest);
			}
		}

		if (client->build_major > 8) {
			unsigned char* nonce = NULL;
			unsigned int nonce_size = 0;
			if (get_ap_nonce(client, &nonce, &nonce_size) < 0) {
				/* the first nonce request with older firmware releases can fail and it's OK */
				info("NOTE: Unable to get nonce from device\n");
			}

			if (!client->nonce || (nonce_size != client->nonce_size) || (memcmp(nonce, client->nonce, nonce_size) != 0)) {
				if (client->nonce) {
					free(client->nonce);
				}
				client->nonce = nonce;
				client->nonce_size = nonce_size;
			} else {
				free(nonce);
			}
			if (client->mode == MODE_NORMAL) {
				plist_t ap_params = normal_get_lockdown_value(client, NULL, "ApParameters");
				if (ap_params) {
					if (!client->parameters) {
						client->parameters = plist_new_dict();
					}
					plist_dict_merge(&client->parameters, ap_params);
					plist_t p_sep_nonce = plist_dict_get_item(ap_params, "SepNonce");
					uint64_t sep_nonce_size = 0;
					const char* sep_nonce = plist_get_data_ptr(p_sep_nonce, &sep_nonce_size);
					info("Getting SepNonce in normal mode... ");
					int i = 0;
					for (i = 0; i < sep_nonce_size; i++) {
						info("%02x ", (unsigned char)sep_nonce[i]);
					}
					info("\n");
					plist_free(ap_params);
				}
				plist_t req_nonce_slot = plist_access_path(build_identity, 2, "Info", "RequiresNonceSlot");
				if (req_nonce_slot) {
					plist_dict_set_item(client->parameters, "RequiresNonceSlot", plist_copy(req_nonce_slot));
				}
			}
		}

		if (client->flags & FLAG_QUIT) {
			return -1;
		}
		
		if (client->mode == MODE_RESTORE && client->root_ticket) {
			plist_t ap_ticket = plist_new_data((char*)client->root_ticket, client->root_ticket_len);
			if (!ap_ticket) {
				error("ERROR: Failed to create ApImg4Ticket node value.\n");
				return -1;
			}
			client->tss = plist_new_dict();
			if (!client->tss) {
				error("ERROR: Failed to create ApImg4Ticket node.\n");
				return -1;
			}
			plist_dict_set_item(client->tss, "ApImg4Ticket", ap_ticket);
		} else {
			if (get_tss_response(client, build_identity, &client->tss) < 0) {
				error("ERROR: Unable to get SHSH blobs for this device\n");
				return -1;
			}
			if (client->macos_variant) {
				if (get_local_policy_tss_response(client, build_identity, &client->tss_localpolicy) < 0) {
					error("ERROR: Unable to get SHSH blobs for this device (local policy)\n");
					return -1;
				}
				if (get_recoveryos_root_ticket_tss_response(client, build_identity, &client->tss_recoveryos_root_ticket) < 0) {
					error("ERROR: Unable to get SHSH blobs for this device (recovery OS Root Ticket)\n");
					return -1;
				}
			} else {
				plist_t recovery_variant = plist_access_path(build_identity, 2, "Info", "RecoveryVariant");
				if (recovery_variant) {
					const char* recovery_variant_str = plist_get_string_ptr(recovery_variant, NULL);
					client->recovery_variant = build_manifest_get_build_identity_for_model_with_variant(client->build_manifest, client->device->hardware_model, recovery_variant_str, 1);
					if (!client->recovery_variant) {
						error("ERROR: Variant '%s' not found in BuildManifest\n", recovery_variant_str);
						return -1;
					}
					if (get_tss_response(client, client->recovery_variant, &client->tss_recoveryos_root_ticket) < 0) {
						error("ERROR: Unable to get SHSH blobs for this device (%s)\n", recovery_variant_str);
						return -1;
					}
				}
			}
		}

		if (stashbag_commit_required) {
			plist_t ticket = plist_dict_get_item(client->tss, "ApImg4Ticket");
			if (!ticket || plist_get_node_type(ticket) != PLIST_DATA) {
				error("ERROR: Missing ApImg4Ticket in TSS response for stashbag commit\n");
				return -1;
			}
			info("Committing stashbag...\n");
			int err = normal_handle_commit_stashbag(client, ticket);
			if (err < 0) {
				error("ERROR: Could not commit stashbag (%d). Aborting.\n", err);
				return -1;
			}
		}
	}

	if (client->flags & FLAG_QUIT) {
		return -1;
	}
	if (client->flags & FLAG_SHSHONLY) {
		if (!tss_enabled) {
			info("This device does not require a TSS record\n");
			return 0;
		}
		if (!client->tss) {
			error("ERROR: could not fetch TSS record\n");
			return -1;
		} else {
			char *bin = NULL;
			uint32_t blen = 0;
			plist_to_bin(client->tss, &bin, &blen);
			if (bin) {
				char zfn[1024];
				if (client->cache_dir) {
					strcpy(zfn, client->cache_dir);
					strcat(zfn, "/shsh");
				} else {
					strcpy(zfn, "shsh");
				}
				mkdir_with_parents(zfn, 0755);
				snprintf(&zfn[0]+strlen(zfn), sizeof(zfn)-strlen(zfn), "/%" PRIu64 "-%s-%s.shsh", client->ecid, client->device->product_type, client->version);
				struct stat fst;
				if (stat(zfn, &fst) != 0) {
					gzFile zf = gzopen(zfn, "wb");
					gzwrite(zf, bin, blen);
					gzclose(zf);
					info("SHSH saved to '%s'\n", zfn);
				} else {
					info("SHSH '%s' already present.\n", zfn);
				}
				free(bin);
			} else {
				error("ERROR: could not get TSS record data\n");
			}
			plist_free(client->tss);
			return 0;
		}
	}

	/* verify if we have tss records if required */
	if ((tss_enabled) && (client->tss == NULL)) {
		error("ERROR: Unable to proceed without a TSS record.\n");
		return -1;
	}

	if ((tss_enabled) && client->tss) {
		/* fix empty dicts */
		fixup_tss(client->tss);
	}
	idevicerestore_progress(client, RESTORE_STEP_PREPARE, 0.25);
	if (client->flags & FLAG_QUIT) {
		return -1;
	}

	// if the device is in normal mode, place device into recovery mode
	if (client->mode == MODE_NORMAL) {
		info("Entering recovery mode...\n");
		if (normal_enter_recovery(client) < 0) {
			error("ERROR: Unable to place device into recovery mode from normal mode\n");
			if (client->tss)
				plist_free(client->tss);
			return -5;
		}
	}

	idevicerestore_progress(client, RESTORE_STEP_PREPARE, 0.3);
	if (client->flags & FLAG_QUIT) {
		return -1;
	}

	if (client->mode == MODE_DFU) {
		// if the device is in DFU mode, place it into recovery mode
		dfu_client_free(client);
		recovery_client_free(client);
		if ((client->flags & FLAG_CUSTOM) && limera1n_is_supported(client->device)) {
			info("connecting to DFU\n");
			if (dfu_client_new(client) < 0) {
				return -1;
			}
			info("exploiting with limera1n\n");
			if (limera1n_exploit(client->device, &client->dfu->client) != 0) {
				error("ERROR: limera1n exploit failed\n");
				dfu_client_free(client);
				return -1;
			}
			dfu_client_free(client);
			info("exploited\n");
		}
		if (dfu_enter_recovery(client, build_identity) < 0) {
			error("ERROR: Unable to place device into recovery mode from DFU mode\n");
			if (client->tss)
				plist_free(client->tss);
			return -2;
		}
	} else if (client->mode == MODE_RECOVERY) {
		// device is in recovery mode
		if ((client->build_major > 8) && !(client->flags & FLAG_CUSTOM)) {
			if (!client->image4supported) {
				/* send ApTicket */
				if (recovery_send_ticket(client) < 0) {
					error("ERROR: Unable to send APTicket\n");
					return -2;
				}
			}
		}

		mutex_lock(&client->device_event_mutex);

		/* now we load the iBEC */
		if (recovery_send_ibec(client, build_identity) < 0) {
			mutex_unlock(&client->device_event_mutex);
			error("ERROR: Unable to send iBEC\n");
			return -2;
		}
		recovery_client_free(client);

		debug("Waiting for device to disconnect...\n");
		cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 60000);
		if (client->mode != MODE_UNKNOWN || (client->flags & FLAG_QUIT)) {
			mutex_unlock(&client->device_event_mutex);

			if (!(client->flags & FLAG_QUIT)) {
				error("ERROR: Device did not disconnect. Possibly invalid iBEC. Reset device and try again.\n");
			}
			return -2;
		}
		recovery_client_free(client);
		debug("Waiting for device to reconnect in recovery mode...\n");
		cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 60000);
		if (client->mode != MODE_RECOVERY || (client->flags & FLAG_QUIT)) {
			mutex_unlock(&client->device_event_mutex);
			if (!(client->flags & FLAG_QUIT)) {
				error("ERROR: Device did not reconnect in recovery mode. Possibly invalid iBEC. Reset device and try again.\n");
			}
			return -2;
		}
		mutex_unlock(&client->device_event_mutex);
	}
	idevicerestore_progress(client, RESTORE_STEP_PREPARE, 0.5);
	if (client->flags & FLAG_QUIT) {
		return -1;
	}

	if (!client->image4supported && (client->build_major > 8)) {
		// we need another tss request with nonce.
		unsigned char* nonce = NULL;
		unsigned int nonce_size = 0;
		int nonce_changed = 0;
		if (get_ap_nonce(client, &nonce, &nonce_size) < 0) {
			error("ERROR: Unable to get nonce from device!\n");
			recovery_send_reset(client);
			return -2;
		}

		if (!client->nonce || (nonce_size != client->nonce_size) || (memcmp(nonce, client->nonce, nonce_size) != 0)) {
			nonce_changed = 1;
			if (client->nonce) {
				free(client->nonce);
			}
			client->nonce = nonce;
			client->nonce_size = nonce_size;
		} else {
			free(nonce);
		}

		if (nonce_changed && !(client->flags & FLAG_CUSTOM)) {
			// Welcome iOS5. We have to re-request the TSS with our nonce.
			plist_free(client->tss);
			if (get_tss_response(client, build_identity, &client->tss) < 0) {
				error("ERROR: Unable to get SHSH blobs for this device\n");
				return -1;
			}
			if (!client->tss) {
				error("ERROR: can't continue without TSS\n");
				return -1;
			}
			fixup_tss(client->tss);
		}
	}
	idevicerestore_progress(client, RESTORE_STEP_PREPARE, 0.7);
	if (client->flags & FLAG_QUIT) {
		return -1;
	}

	// now finally do the magic to put the device into restore mode
	if (client->mode == MODE_RECOVERY) {
		if (recovery_enter_restore(client, build_identity) < 0) {
			error("ERROR: Unable to place device into restore mode\n");
			if (client->tss)
				plist_free(client->tss);
			return -2;
		}
		recovery_client_free(client);
	}
	idevicerestore_progress(client, RESTORE_STEP_PREPARE, 0.9);

	if (client->mode != MODE_RESTORE) {
		mutex_lock(&client->device_event_mutex);
		info("Waiting for device to enter restore mode...\n");
		cond_wait_timeout(&client->device_event_cond, &client->device_event_mutex, 180000);
		if (client->mode != MODE_RESTORE || (client->flags & FLAG_QUIT)) {
			mutex_unlock(&client->device_event_mutex);
			error("ERROR: Device failed to enter restore mode.\n");
			if (client->mode == MODE_UNKNOWN) {
				error("Make sure that usbmuxd is running.\n");
			} else if (client->mode == MODE_RECOVERY) {
				error("Device reconnected in recovery mode, most likely image personalization failed.\n");
			}
			return -1;
		}
		mutex_unlock(&client->device_event_mutex);
	}

	// device is finally in restore mode, let's do this
	if (client->mode == MODE_RESTORE) {
		if ((client->flags & FLAG_NO_RESTORE) != 0) {
			info("Device is now in restore mode. Exiting as requested.\n");
			return 0;
		}
		client->ignore_device_add_events = 1;
		info("About to restore device... \n");
		result = restore_device(client, build_identity);
		if (result < 0) {
			error("ERROR: Unable to restore device\n");
			return result;
		}
	}

	/* special handling of older AppleTVs as they enter Recovery mode on boot when plugged in to USB */
	if ((strncmp(client->device->product_type, "AppleTV", 7) == 0) && (client->device->product_type[7] < '5')) {
		if (recovery_client_new(client) == 0) {
			if (recovery_set_autoboot(client, 1) == 0) {
				recovery_send_reset(client);
			} else {
				error("Setting auto-boot failed?!\n");
			}
		} else {
			error("Could not connect to device in recovery mode.\n");
		}
	}

	if (result == 0) {
		debug("DONE\n"); //Denis
		idevicerestore_progress(client, RESTORE_NUM_STEPS-1, 1.0);
	} else {
		debug("RESTORE FAILED\n"); //Denis
	}

	if (build_identity_needs_free)
		plist_free(build_identity);

	return result;
}

struct idevicerestore_client_t* idevicerestore_client_new(void)
{
	struct idevicerestore_client_t* client = (struct idevicerestore_client_t*) malloc(sizeof(struct idevicerestore_client_t));
	if (client == NULL) {
		error("ERROR: Out of memory\n");
		return NULL;
	}
	memset(client, '\0', sizeof(struct idevicerestore_client_t));
	client->mode = MODE_UNKNOWN;

	mutex_init(&client->device_event_mutex);
	cond_init(&client->device_event_cond);
	return client;
}

void idevicerestore_client_free(struct idevicerestore_client_t* client)
{
	if (!client) {
		return;
	}

	if (client->irecv_e_ctx) {
		irecv_device_event_unsubscribe(client->irecv_e_ctx);
	}
	if (client->idevice_e_ctx) {
		idevice_event_unsubscribe();
	}
	cond_destroy(&client->device_event_cond);
	mutex_destroy(&client->device_event_mutex);

	if (client->tss_url) {
		free(client->tss_url);
	}
	if (client->version_data) {
		plist_free(client->version_data);
	}
	if (client->nonce) {
		free(client->nonce);
	}
	if (client->udid) {
		free(client->udid);
	}
	if (client->srnm) {
		free(client->srnm);
	}
	if (client->ipsw) {
		ipsw_close(client->ipsw);
	}
	if (client->filesystem) {
		if (client->delete_fs) {
			unlink(client->filesystem);
		}
		free(client->filesystem);
	}
	free(client->version);
	free(client->build);
	free(client->device_version);
	free(client->device_build);
	if (client->restore_boot_args) {
		free(client->restore_boot_args);
	}
	if (client->cache_dir) {
		free(client->cache_dir);
	}
	if (client->root_ticket) {
		free(client->root_ticket);
	}
	if (client->build_manifest) {
		plist_free(client->build_manifest);
	}
	if (client->firmware_preflight_info) {
		plist_free(client->firmware_preflight_info);
	}
	if (client->preflight_info) {
		plist_free(client->preflight_info);
	}
	free(client->restore_variant);
	free(client);
}

void idevicerestore_set_ecid(struct idevicerestore_client_t* client, uint64_t ecid)
{
	if (!client)
		return;
	client->ecid = ecid;
}

void idevicerestore_set_udid(struct idevicerestore_client_t* client, const char* udid)
{
	if (!client)
		return;
	if (client->udid) {
		free(client->udid);
		client->udid = NULL;
	}
	if (udid) {
		client->udid = strdup(udid);
	}
}

void idevicerestore_set_flags(struct idevicerestore_client_t* client, int flags)
{
	if (!client)
		return;
	client->flags = flags;
}

void idevicerestore_set_ipsw(struct idevicerestore_client_t* client, const char* path)
{
	if (!client)
		return;
	if (client->ipsw) {
		ipsw_close(client->ipsw);
		client->ipsw = NULL;
	}
	if (path) {
		client->ipsw = ipsw_open(path);
	}
}

void idevicerestore_set_cache_path(struct idevicerestore_client_t* client, const char* path)
{
	if (!client)
		return;
	if (client->cache_dir) {
		free(client->cache_dir);
		client->cache_dir = NULL;
	}
	if (path) {
		client->cache_dir = strdup(path);
	}
}

void idevicerestore_set_progress_callback(struct idevicerestore_client_t* client, idevicerestore_progress_cb_t cbfunc, void* userdata)
{
	if (!client)
		return;
	client->progress_cb = cbfunc;
	client->progress_cb_data = userdata;
}

#ifndef IDEVICERESTORE_NOMAIN
static struct idevicerestore_client_t* idevicerestore_client = NULL;

static void handle_signal(int sig)
{
	if (idevicerestore_client) {
		idevicerestore_client->flags |= FLAG_QUIT;
		ipsw_cancel();
	}
}

void plain_progress_cb(int step, double step_progress, void* userdata)
{
	printf("progress: %u %f\n", step, step_progress);
	fflush(stdout);
}

int main(int argc, char* argv[]) {
	int opt = 0;
	int optindex = 0;
	char* ipsw = NULL;
	int ipsw_info = 0;
	int result = 0;

	struct idevicerestore_client_t* client = idevicerestore_client_new();
	if (client == NULL) {
		error("ERROR: could not create idevicerestore client\n");
		return EXIT_FAILURE;
	}

	idevicerestore_client = client;

#ifdef WIN32
	signal(SIGINT, handle_signal);
	signal(SIGTERM, handle_signal);
	signal(SIGABRT, handle_signal);
#else
	struct sigaction sa;
	memset(&sa, 0, sizeof(struct sigaction));
	sa.sa_handler = handle_signal;
	sigaction(SIGINT, &sa, NULL);
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGQUIT, &sa, NULL);
	sa.sa_handler = SIG_IGN;
	sigaction(SIGPIPE, &sa, NULL);
#endif

	if (!isatty(fileno(stdin)) || !isatty(fileno(stdout))) {
		client->flags &= ~FLAG_INTERACTIVE;
	} else {
		client->flags |= FLAG_INTERACTIVE;
	}

	while ((opt = getopt_long(argc, argv, "dhces:xtpli:u:nC:kyPRT:zv", longopts, &optindex)) > 0) {
		switch (opt) {
		case 'h':
			usage(argc, argv, 0);
			return EXIT_SUCCESS;

		case 'd':
			client->flags |= FLAG_DEBUG;
			client->debug_level++;
			break;

		case 'e':
			client->flags |= FLAG_ERASE;
			break;

		case 'c':
			client->flags |= FLAG_CUSTOM;
			break;

		case 's': {
			if (!*optarg) {
				error("ERROR: URL argument for --server must not be empty!\n");
				usage(argc, argv, 1);
				return EXIT_FAILURE;
			}
			char *baseurl = NULL;
			if (!strncmp(optarg, "http://", 7) && (strlen(optarg) > 7) && (optarg[7] != '/')) {
				baseurl = optarg+7;
			} else if (!strncmp(optarg, "https://", 8) && (strlen(optarg) > 8) && (optarg[8] != '/')) {
				baseurl = optarg+8;
			}
			if (baseurl) {
				char *p = strchr(baseurl, '/');
				if (!p || *(p+1) == '\0') {
					// no path component, add default path
					const char default_path[] = "/TSS/controller?action=2";
					size_t usize = strlen(optarg)+sizeof(default_path);
					char* newurl = malloc(usize);
					snprintf(newurl, usize, "%s%s", optarg, (p) ? default_path+1 : default_path);
					client->tss_url = newurl;
				} else {
					client->tss_url = strdup(optarg);
				}
			} else {
				error("ERROR: URL argument for --server is invalid, must start with http:// or https://\n");
				usage(argc, argv, 1);
				return EXIT_FAILURE;
			}
		}
			break;

		case 'x':
			client->flags |= FLAG_EXCLUDE;
			break;

		case 'l':
			client->flags |= FLAG_LATEST;
			break;

		case 'i':
			if (optarg) {
				char* tail = NULL;
				client->ecid = strtoull(optarg, &tail, 0);
				if (tail && (tail[0] != '\0')) {
					client->ecid = 0;
				}
				if (client->ecid == 0) {
					error("ERROR: Could not parse ECID from '%s'\n", optarg);
					return EXIT_FAILURE;
				}
			}
			break;

		case 'u':
			if (!*optarg) {
				error("ERROR: UDID must not be empty!\n");
				usage(argc, argv, 1);
				return EXIT_FAILURE;
			}
			client->udid = strdup(optarg);
			break;

		case 't':
			client->flags |= FLAG_SHSHONLY;
			break;

		case 'k':
			idevicerestore_keep_pers = 1;
			break;

		case 'p':
			client->flags |= FLAG_PWN;
			break;

		case 'n':
			client->flags |= FLAG_NOACTION;
			break;

		case 'C':
			client->cache_dir = strdup(optarg);
			break;

		case 'y':
			client->flags &= ~FLAG_INTERACTIVE;
			break;

		case 'P':
			idevicerestore_set_progress_callback(client, plain_progress_cb, NULL);
			break;

		case 'R':
			client->flags |= FLAG_ALLOW_RESTORE_MODE;
			break;

		case 'z':
			client->flags |= FLAG_NO_RESTORE;
			break;

		case 'v':
			info("%s %s (libirecovery %s, libtatsu %s)\n", PACKAGE_NAME, PACKAGE_VERSION, irecv_version(), libtatsu_version());
			return EXIT_SUCCESS;

		case 'T': {
			size_t root_ticket_len = 0;
			unsigned char* root_ticket = NULL;
			if (read_file(optarg, (void**)&root_ticket, &root_ticket_len) != 0) {
				return EXIT_FAILURE;
			}
			client->root_ticket = root_ticket;
			client->root_ticket_len = (int)root_ticket_len;
			info("Using ApTicket found at %s length %u\n", optarg, client->root_ticket_len);
			break;
		}

		case 'I':
			ipsw_info = 1;
			break;

		case 1:
			client->flags |= FLAG_IGNORE_ERRORS;
			break;

		case 2:
			free(client->restore_variant);
			client->restore_variant = strdup(optarg);
			break;

		default:
			usage(argc, argv, 1);
			return EXIT_FAILURE;
		}
	}

	if (ipsw_info) {
		if (argc-optind != 1) {
			error("ERROR: --ipsw-info requires an IPSW path.\n");
			usage(argc, argv, 1);
			return EXIT_FAILURE;
		}
		return (ipsw_print_info(*(argv + optind)) == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
	}

	if (((argc-optind) == 1) || (client->flags & FLAG_PWN) || (client->flags & FLAG_LATEST)) {
		argc -= optind;
		argv += optind;

		ipsw = argv[0];
	} else {
		usage(argc, argv, 1);
		return EXIT_FAILURE;
	}

	if ((client->flags & FLAG_LATEST) && (client->flags & FLAG_CUSTOM)) {
		error("ERROR: You can't use --custom and --latest options at the same time.\n");
		return EXIT_FAILURE;
	}

	info("%s %s (libirecovery %s, libtatsu %s)\n", PACKAGE_NAME, PACKAGE_VERSION, irecv_version(), libtatsu_version());

	if (ipsw) {
		// verify if ipsw file exists
		client->ipsw = ipsw_open(ipsw);
		if (!client->ipsw) {
			error("ERROR: Firmware file %s cannot be opened.\n", ipsw);
			return -1;
		}
	}

	curl_global_init(CURL_GLOBAL_ALL);

	result = idevicerestore_start(client);

	idevicerestore_client_free(client);

	curl_global_cleanup();

	return (result == 0) ? EXIT_SUCCESS : EXIT_FAILURE;
}
#endif

irecv_device_t get_irecv_device(struct idevicerestore_client_t *client)
{
	int mode = _MODE_UNKNOWN;

	if (client->mode) {
		mode = client->mode->index;
	}

	switch (mode) {
	case _MODE_RESTORE:
		return restore_get_irecv_device(client);

	case _MODE_NORMAL:
		return normal_get_irecv_device(client);

	case _MODE_DFU:
	case _MODE_PORTDFU:
	case _MODE_RECOVERY:
		return dfu_get_irecv_device(client);

	default:
		return NULL;
	}
}

int is_image4_supported(struct idevicerestore_client_t* client)
{
	int res = 0;
	int mode = _MODE_UNKNOWN;

	if (client->mode) {
		mode = client->mode->index;
	}

	switch (mode) {
	case _MODE_NORMAL:
		res = normal_is_image4_supported(client);
		break;
	case _MODE_RESTORE:
		res = restore_is_image4_supported(client);
		break;
	case _MODE_DFU:
		res = dfu_is_image4_supported(client);
		break;
	case _MODE_RECOVERY:
		res = recovery_is_image4_supported(client);
		break;
	default:
		error("ERROR: Device is in an invalid state\n");
		return 0;
	}
	return res;
}

int get_ap_nonce(struct idevicerestore_client_t* client, unsigned char** nonce, unsigned int* nonce_size)
{
	int mode = _MODE_UNKNOWN;

	*nonce = NULL;
	*nonce_size = 0;

	info("Getting ApNonce ");

	if (client->mode) {
		mode = client->mode->index;
	}

	switch (mode) {
	case _MODE_NORMAL:
		info("in normal mode... ");
		if (normal_get_ap_nonce(client, nonce, nonce_size) < 0) {
			info("failed\n");
			return -1;
		}
		break;
	case _MODE_DFU:
		info("in dfu mode... ");
		if (dfu_get_ap_nonce(client, nonce, nonce_size) < 0) {
			info("failed\n");
			return -1;
		}
		break;
	case _MODE_RECOVERY:
		info("in recovery mode... ");
		if (recovery_get_ap_nonce(client, nonce, nonce_size) < 0) {
			info("failed\n");
			return -1;
		}
		break;

	default:
		info("failed\n");
		error("ERROR: Device is in an invalid state\n");
		return -1;
	}

	int i = 0;
	for (i = 0; i < *nonce_size; i++) {
		info("%02x ", (*nonce)[i]);
	}
	info("\n");

	return 0;
}

int get_sep_nonce(struct idevicerestore_client_t* client, unsigned char** nonce, unsigned int* nonce_size)
{
	int mode = _MODE_UNKNOWN;

	*nonce = NULL;
	*nonce_size = 0;

	info("Getting SepNonce ");

	if (client->mode) {
		mode = client->mode->index;
	}

	switch (mode) {
	case _MODE_NORMAL:
		info("in normal mode... ");
		if (normal_get_sep_nonce(client, nonce, nonce_size) < 0) {
			info("failed\n");
			return -1;
		}
		break;
	case _MODE_DFU:
		info("in dfu mode... ");
		if (dfu_get_sep_nonce(client, nonce, nonce_size) < 0) {
			info("failed\n");
			return -1;
		}
		break;
	case _MODE_RECOVERY:
		info("in recovery mode... ");
		if (recovery_get_sep_nonce(client, nonce, nonce_size) < 0) {
			info("failed\n");
			return -1;
		}
		break;

	default:
		info("failed\n");
		error("ERROR: Device is in an invalid state\n");
		return -1;
	}

	int i = 0;
	for (i = 0; i < *nonce_size; i++) {
		info("%02x ", (*nonce)[i]);
	}
	info("\n");

	return 0;
}

plist_t build_manifest_get_build_identity_for_model_with_variant(plist_t build_manifest, const char *hardware_model, const char *variant, int exact)
{
	plist_t build_identities_array = plist_dict_get_item(build_manifest, "BuildIdentities");
	if (!build_identities_array || plist_get_node_type(build_identities_array) != PLIST_ARRAY) {
		error("ERROR: Unable to find build identities node\n");
		return NULL;
	}

	uint32_t i;
	for (i = 0; i < plist_array_get_size(build_identities_array); i++) {
		plist_t ident = plist_array_get_item(build_identities_array, i);
		if (!ident || plist_get_node_type(ident) != PLIST_DICT) {
			continue;
		}
		plist_t info_dict = plist_dict_get_item(ident, "Info");
		if (!info_dict || plist_get_node_type(ident) != PLIST_DICT) {
			continue;
		}
		plist_t devclass = plist_dict_get_item(info_dict, "DeviceClass");
		if (!devclass || plist_get_node_type(devclass) != PLIST_STRING) {
			continue;
		}
		const char *str = plist_get_string_ptr(devclass, NULL);
		if (strcasecmp(str, hardware_model) != 0) {
			continue;
		}
		if (variant) {
			plist_t rvariant = plist_dict_get_item(info_dict, "Variant");
			if (!rvariant || plist_get_node_type(rvariant) != PLIST_STRING) {
				continue;
			}
			str = plist_get_string_ptr(rvariant, NULL);
			if (strcmp(str, variant) != 0) {
				/* if it's not a full match, let's try a partial match, but ignore "*Research*" */
				if (!exact && strstr(str, variant) && !strstr(str, "Research")) {
					return ident;
				}
				continue;
			} else {
				return ident;
			}
		} else {
			return ident;
		}
	}

	return NULL;
}

plist_t build_manifest_get_build_identity_for_model(plist_t build_manifest, const char *hardware_model)
{
	return build_manifest_get_build_identity_for_model_with_variant(build_manifest, hardware_model, NULL, 0);
}

int get_preboard_manifest(struct idevicerestore_client_t* client, plist_t build_identity, plist_t* manifest)
{
	plist_t request = NULL;
	*manifest = NULL;

	if (!client->image4supported) {
		return -1;
	}

	/* populate parameters */
	plist_t parameters = plist_new_dict();

	plist_t overrides = plist_new_dict();
	plist_dict_set_item(overrides, "@APTicket", plist_new_bool(1));
	plist_dict_set_item(overrides, "ApProductionMode", plist_new_uint(0));
	plist_dict_set_item(overrides, "ApSecurityDomain", plist_new_uint(1));

	plist_dict_set_item(parameters, "ApProductionMode", plist_new_bool(0));
	plist_dict_set_item(parameters, "ApSecurityMode", plist_new_bool(0));
	plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(1));

	tss_parameters_add_from_manifest(parameters, build_identity, true);

	/* create basic request */
	request = tss_request_new(NULL);
	if (request == NULL) {
		error("ERROR: Unable to create TSS request\n");
		plist_free(parameters);
		return -1;
	}

	/* add common tags from manifest */
	if (tss_request_add_common_tags(request, parameters, overrides) < 0) {
		error("ERROR: Unable to add common tags\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	plist_dict_set_item(parameters, "_OnlyFWComponents", plist_new_bool(1));

	/* add tags from manifest */
	if (tss_request_add_ap_tags(request, parameters, NULL) < 0) {
		error("ERROR: Unable to add ap tags\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	plist_t local_manifest = NULL;
	int res = img4_create_local_manifest(request, build_identity, &local_manifest);

	*manifest = local_manifest;

	plist_free(request);
	plist_free(parameters);
	plist_free(overrides);

	return res;
}

int get_tss_response(struct idevicerestore_client_t* client, plist_t build_identity, plist_t* tss)
{
	plist_t request = NULL;
	plist_t response = NULL;
	*tss = NULL;

	if ((client->build_major <= 8) || (client->flags & FLAG_CUSTOM)) {
		error("checking for local shsh\n");

		/* first check for local copy */
		char zfn[1024];
		if (client->version) {
			if (client->cache_dir) {
				snprintf(zfn, sizeof(zfn), "%s/shsh/%" PRIu64 "-%s-%s.shsh", client->cache_dir, client->ecid, client->device->product_type, client->version);
			} else {
				snprintf(zfn, sizeof(zfn), "shsh/%" PRIu64 "-%s-%s.shsh", client->ecid, client->device->product_type, client->version);
			}
			struct stat fst;
			if (stat(zfn, &fst) == 0) {
				gzFile zf = gzopen(zfn, "rb");
				if (zf) {
					int blen = 0;
					int readsize = 16384;
					int bufsize = readsize;
					char* bin = (char*)malloc(bufsize);
					char* p = bin;
					do {
						int bytes_read = gzread(zf, p, readsize);
						if (bytes_read < 0) {
							fprintf(stderr, "Error reading gz compressed data\n");
							exit(EXIT_FAILURE);
						}
						blen += bytes_read;
						if (bytes_read < readsize) {
							if (gzeof(zf)) {
								bufsize += bytes_read;
								break;
							}
						}
						bufsize += readsize;
						bin = realloc(bin, bufsize);
						p = bin + blen;
					} while (!gzeof(zf));
					gzclose(zf);
					if (blen > 0) {
						if (memcmp(bin, "bplist00", 8) == 0) {
							plist_from_bin(bin, blen, tss);
						} else {
							plist_from_xml(bin, blen, tss);
						}
					}
					free(bin);
				}
			} else {
				error("no local file %s\n", zfn);
			}
		} else {
			error("No version found?!\n");
		}
	}

	if (*tss) {
		info("Using cached SHSH\n");
		return 0;
	} else {
		info("Trying to fetch new SHSH blob\n");
	}

	/* populate parameters */
	plist_t parameters = plist_new_dict();
	plist_dict_merge(&parameters, client->parameters);

	plist_dict_set_item(parameters, "ApECID", plist_new_uint(client->ecid));
	if (client->nonce) {
		plist_dict_set_item(parameters, "ApNonce", plist_new_data((const char*)client->nonce, client->nonce_size));
	}

	if (!plist_dict_get_item(parameters, "SepNonce")) {
		unsigned char* sep_nonce = NULL;
		unsigned int sep_nonce_size = 0;
		get_sep_nonce(client, &sep_nonce, &sep_nonce_size);
		if (sep_nonce) {
			plist_dict_set_item(parameters, "ApSepNonce", plist_new_data((const char*)sep_nonce, sep_nonce_size));
			free(sep_nonce);
		}
	}

	plist_dict_set_item(parameters, "ApProductionMode", plist_new_bool(1));
	if (client->image4supported) {
		plist_dict_set_item(parameters, "ApSecurityMode", plist_new_bool(1));
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(1));
	} else {
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(0));
	}

	tss_parameters_add_from_manifest(parameters, build_identity, true);

	/* create basic request */
	request = tss_request_new(NULL);
	if (request == NULL) {
		error("ERROR: Unable to create TSS request\n");
		plist_free(parameters);
		return -1;
	}

	/* add common tags from manifest */
	if (tss_request_add_common_tags(request, parameters, NULL) < 0) {
		error("ERROR: Unable to add common tags to TSS request\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	/* add tags from manifest */
	if (tss_request_add_ap_tags(request, parameters, NULL) < 0) {
		error("ERROR: Unable to add common tags to TSS request\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	if (client->image4supported) {
		/* add personalized parameters */
		if (tss_request_add_ap_img4_tags(request, parameters) < 0) {
			error("ERROR: Unable to add img4 tags to TSS request\n");
			plist_free(request);
			plist_free(parameters);
			return -1;
		}
	} else {
		/* add personalized parameters */
		if (tss_request_add_ap_img3_tags(request, parameters) < 0) {
			error("ERROR: Unable to add img3 tags to TSS request\n");
			plist_free(request);
			plist_free(parameters);
			return -1;
		}
	}

	if (client->mode == MODE_NORMAL) {
		/* normal mode; request baseband ticket aswell */
		plist_t pinfo = NULL;
		normal_get_firmware_preflight_info(client, &pinfo);
		if (pinfo) {
			plist_dict_copy_data(parameters, pinfo, "BbNonce", "Nonce");
			plist_dict_copy_uint(parameters, pinfo, "BbChipID", "ChipID");
			plist_dict_copy_uint(parameters, pinfo, "BbGoldCertId", "CertID");
			plist_dict_copy_data(parameters, pinfo, "BbSNUM", "ChipSerialNo");

			/* add baseband parameters */
			tss_request_add_baseband_tags(request, parameters, NULL);

			plist_dict_copy_uint(parameters, pinfo, "eUICC,ChipID", "EUICCChipID");
			if (plist_dict_get_uint(parameters, "eUICC,ChipID") >= 5) {
				plist_dict_copy_data(parameters, pinfo, "eUICC,EID", "EUICCCSN");
				plist_dict_copy_data(parameters, pinfo, "eUICC,RootKeyIdentifier", "EUICCCertIdentifier");
				plist_dict_copy_data(parameters, pinfo, "EUICCGoldNonce", NULL);
				plist_dict_copy_data(parameters, pinfo, "EUICCMainNonce", NULL);

				/* add vinyl parameters */
				tss_request_add_vinyl_tags(request, parameters, NULL);
			}
		}
		client->firmware_preflight_info = pinfo;
		pinfo = NULL;

		normal_get_preflight_info(client, &pinfo);
		client->preflight_info = pinfo;
	}

	/* send request and grab response */
	response = tss_request_send(request, client->tss_url);
	if (response == NULL) {
		info("ERROR: Unable to send TSS request 2\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	info("Received SHSH blobs\n");

	plist_free(request);
	plist_free(parameters);

	*tss = response;

	return 0;
}

int get_recoveryos_root_ticket_tss_response(struct idevicerestore_client_t* client, plist_t build_identity, plist_t* tss)
{
	plist_t request = NULL;
	plist_t response = NULL;
	*tss = NULL;

	/* populate parameters */
	plist_t parameters = plist_new_dict();

	/* ApECID */
	plist_dict_set_item(parameters, "ApECID", plist_new_uint(client->ecid));
	plist_dict_set_item(parameters, "Ap,LocalBoot", plist_new_bool(0));

	/* ApNonce */
	if (client->nonce) {
		plist_dict_set_item(parameters, "ApNonce", plist_new_data((const char*)client->nonce, client->nonce_size));
	}
	unsigned char* sep_nonce = NULL;
	unsigned int sep_nonce_size = 0;
	get_sep_nonce(client, &sep_nonce, &sep_nonce_size);

	/* ApSepNonce */
	if (sep_nonce) {
		plist_dict_set_item(parameters, "ApSepNonce", plist_new_data((const char*)sep_nonce, sep_nonce_size));
		free(sep_nonce);
	}

	/* ApProductionMode */
	plist_dict_set_item(parameters, "ApProductionMode", plist_new_bool(1));

	/* ApSecurityMode */
	if (client->image4supported) {
		plist_dict_set_item(parameters, "ApSecurityMode", plist_new_bool(1));
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(1));
	} else {
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(0));
	}

	tss_parameters_add_from_manifest(parameters, build_identity, true);

	/* create basic request */
	/* Adds @HostPlatformInfo, @VersionInfo, @UUID */
	request = tss_request_new(NULL);
	if (request == NULL) {
		error("ERROR: Unable to create TSS request\n");
		plist_free(parameters);
		return -1;
	}

	/* add common tags from manifest */
	/* Adds Ap,OSLongVersion, ApNonce, @ApImg4Ticket */
	if (tss_request_add_ap_img4_tags(request, parameters) < 0) {
		error("ERROR: Unable to add AP IMG4 tags to TSS request\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	/* add AP tags from manifest */
	if (tss_request_add_common_tags(request, parameters, NULL) < 0) {
		error("ERROR: Unable to add common tags to TSS request\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	/* add AP tags from manifest */
	/* Fills digests & co */
	if (tss_request_add_ap_recovery_tags(request, parameters, NULL) < 0) {
		error("ERROR: Unable to add common tags to TSS request\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	/* send request and grab response */
	response = tss_request_send(request, client->tss_url);
	if (response == NULL) {
		info("ERROR: Unable to send TSS request 3\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}
	// request_add_ap_tags

	info("Received SHSH blobs\n");

	plist_free(request);
	plist_free(parameters);

	*tss = response;

	return 0;
}

int get_recovery_os_local_policy_tss_response(
				struct idevicerestore_client_t* client,
				plist_t build_identity,
				plist_t* tss,
				plist_t args)
{
	plist_t request = NULL;
	plist_t response = NULL;
	*tss = NULL;

	/* populate parameters */
	plist_t parameters = plist_new_dict();
	plist_dict_set_item(parameters, "ApECID", plist_new_uint(client->ecid));
	plist_dict_set_item(parameters, "Ap,LocalBoot", plist_new_bool(1));

	plist_dict_set_item(parameters, "ApProductionMode", plist_new_bool(1));
	if (client->image4supported) {
		plist_dict_set_item(parameters, "ApSecurityMode", plist_new_bool(1));
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(1));
	} else {
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(0));
	}

	tss_parameters_add_from_manifest(parameters, build_identity, true);

	// Add Ap,LocalPolicy
	uint8_t digest[SHA384_DIGEST_LENGTH];
	sha384(lpol_file, lpol_file_length, digest);
	plist_t lpol = plist_new_dict();
	plist_dict_set_item(lpol, "Digest", plist_new_data((char*)digest, SHA384_DIGEST_LENGTH));
	plist_dict_set_item(lpol, "Trusted", plist_new_bool(1));
	plist_dict_set_item(parameters, "Ap,LocalPolicy", lpol);

	plist_dict_copy_data(parameters, args, "Ap,NextStageIM4MHash", NULL);
	plist_dict_copy_data(parameters, args, "Ap,RecoveryOSPolicyNonceHash", NULL);

	plist_t vol_uuid_node = plist_dict_get_item(args, "Ap,VolumeUUID");
	char* vol_uuid_str = NULL;
	plist_get_string_val(vol_uuid_node, &vol_uuid_str);
	unsigned int vuuid[16];
	unsigned char vol_uuid[16];
	if (sscanf(vol_uuid_str, "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x", &vuuid[0], &vuuid[1], &vuuid[2], &vuuid[3], &vuuid[4], &vuuid[5], &vuuid[6], &vuuid[7], &vuuid[8], &vuuid[9], &vuuid[10], &vuuid[11], &vuuid[12], &vuuid[13], &vuuid[14], &vuuid[15]) != 16) {
		error("ERROR: Failed to parse Ap,VolumeUUID (%s)\n", vol_uuid_str);
		free(vol_uuid_str);
		return -1;
	}
	free(vol_uuid_str);
	int i;
	for (i = 0; i < 16; i++) {
		vol_uuid[i] = (unsigned char)vuuid[i];
	}
	plist_dict_set_item(parameters, "Ap,VolumeUUID", plist_new_data((char*)vol_uuid, 16));

	/* create basic request */
	request = tss_request_new(NULL);
	if (request == NULL) {
		error("ERROR: Unable to create TSS request\n");
		plist_free(parameters);
		return -1;
	}

	/* add common tags from manifest */
	if (tss_request_add_local_policy_tags(request, parameters) < 0) {
		error("ERROR: Unable to add common tags to TSS request\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	/* send request and grab response */
	response = tss_request_send(request, client->tss_url);
	if (response == NULL) {
		info("ERROR: Unable to send TSS request 4\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	info("Received SHSH blobs\n");

	plist_free(request);
	plist_free(parameters);

	*tss = response;

	return 0;
}

int get_local_policy_tss_response(struct idevicerestore_client_t* client, plist_t build_identity, plist_t* tss)
{
	plist_t request = NULL;
	plist_t response = NULL;
	*tss = NULL;

	/* populate parameters */
	plist_t parameters = plist_new_dict();
	plist_dict_set_item(parameters, "ApECID", plist_new_uint(client->ecid));
	plist_dict_set_item(parameters, "Ap,LocalBoot", plist_new_bool(0));
	if (client->nonce) {
		plist_dict_set_item(parameters, "ApNonce", plist_new_data((const char*)client->nonce, client->nonce_size));
	}
	unsigned char* sep_nonce = NULL;
	unsigned int sep_nonce_size = 0;
	get_sep_nonce(client, &sep_nonce, &sep_nonce_size);

	if (sep_nonce) {
		plist_dict_set_item(parameters, "ApSepNonce", plist_new_data((const char*)sep_nonce, sep_nonce_size));
		free(sep_nonce);
	}

	plist_dict_set_item(parameters, "ApProductionMode", plist_new_bool(1));
	if (client->image4supported) {
		plist_dict_set_item(parameters, "ApSecurityMode", plist_new_bool(1));
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(1));
	} else {
		plist_dict_set_item(parameters, "ApSupportsImg4", plist_new_bool(0));
	}

	tss_parameters_add_from_manifest(parameters, build_identity, true);

	// Add Ap,LocalPolicy
	uint8_t digest[SHA384_DIGEST_LENGTH];
	sha384(lpol_file, lpol_file_length, digest);
	plist_t lpol = plist_new_dict();
	plist_dict_set_item(lpol, "Digest", plist_new_data((char*)digest, SHA384_DIGEST_LENGTH));
	plist_dict_set_item(lpol, "Trusted", plist_new_bool(1));
	plist_dict_set_item(parameters, "Ap,LocalPolicy", lpol);

	// Add Ap,NextStageIM4MHash
	// Get previous TSS ticket
	uint8_t* ticket = NULL;
	uint32_t ticket_length = 0;
	tss_response_get_ap_img4_ticket(client->tss, &ticket, &ticket_length);
	// Hash it and add it as Ap,NextStageIM4MHash
	uint8_t hash[SHA384_DIGEST_LENGTH];
	sha384(ticket, ticket_length, hash);
	plist_dict_set_item(parameters, "Ap,NextStageIM4MHash", plist_new_data((char*)hash, SHA384_DIGEST_LENGTH));

	/* create basic request */
	request = tss_request_new(NULL);
	if (request == NULL) {
		error("ERROR: Unable to create TSS request\n");
		plist_free(parameters);
		return -1;
	}

	/* add common tags from manifest */
	if (tss_request_add_local_policy_tags(request, parameters) < 0) {
		error("ERROR: Unable to add common tags to TSS request\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	/* send request and grab response */
	response = tss_request_send(request, client->tss_url);
	if (response == NULL) {
		info("ERROR: Unable to send TSS request 5\n");
		plist_free(request);
		plist_free(parameters);
		return -1;
	}

	info("Received SHSH blobs\n");

	plist_free(request);
	plist_free(parameters);

	*tss = response;

	return 0;
}

void fixup_tss(plist_t tss)
{
	plist_t node;
	plist_t node2;
	node = plist_dict_get_item(tss, "RestoreLogo");
	if (node && (plist_get_node_type(node) == PLIST_DICT) && (plist_dict_get_size(node) == 0)) {
		node2 = plist_dict_get_item(tss, "AppleLogo");
		if (node2 && (plist_get_node_type(node2) == PLIST_DICT)) {
			plist_dict_remove_item(tss, "RestoreLogo");
			plist_dict_set_item(tss, "RestoreLogo", plist_copy(node2));
		}
	}
	node = plist_dict_get_item(tss, "RestoreDeviceTree");
	if (node && (plist_get_node_type(node) == PLIST_DICT) && (plist_dict_get_size(node) == 0)) {
		node2 = plist_dict_get_item(tss, "DeviceTree");
		if (node2 && (plist_get_node_type(node2) == PLIST_DICT)) {
			plist_dict_remove_item(tss, "RestoreDeviceTree");
			plist_dict_set_item(tss, "RestoreDeviceTree", plist_copy(node2));
		}
	}
	node = plist_dict_get_item(tss, "RestoreKernelCache");
	if (node && (plist_get_node_type(node) == PLIST_DICT) && (plist_dict_get_size(node) == 0)) {
		node2 = plist_dict_get_item(tss, "KernelCache");
		if (node2 && (plist_get_node_type(node2) == PLIST_DICT)) {
			plist_dict_remove_item(tss, "RestoreKernelCache");
			plist_dict_set_item(tss, "RestoreKernelCache", plist_copy(node2));
		}
	}
}

int build_manifest_get_identity_count(plist_t build_manifest)
{
	// fetch build identities array from BuildManifest
	plist_t build_identities_array = plist_dict_get_item(build_manifest, "BuildIdentities");
	if (!build_identities_array || plist_get_node_type(build_identities_array) != PLIST_ARRAY) {
		error("ERROR: Unable to find build identities node\n");
		return -1;
	}
	return plist_array_get_size(build_identities_array);
}

int extract_component(ipsw_archive_t ipsw, const char* path, unsigned char** component_data, unsigned int* component_size)
{
	char* component_name = NULL;
	if (!ipsw || !path || !component_data || !component_size) {
		return -1;
	}

	component_name = strrchr(path, '/');
	if (component_name != NULL)
		component_name++;
	else
		component_name = (char*) path;

	info("Extracting %s (%s)...\n", component_name, path);
	if (ipsw_extract_to_memory(ipsw, path, component_data, component_size) < 0) {
		error("ERROR: Unable to extract %s from %s\n", component_name, ipsw->path);
		return -1;
	}

	return 0;
}

int personalize_component(struct idevicerestore_client_t* client, const char *component_name, const unsigned char* component_data, unsigned int component_size, plist_t tss_response, unsigned char** personalized_component, unsigned int* personalized_component_size)
{
	unsigned char* component_blob = NULL;
	unsigned int component_blob_size = 0;
	unsigned char* stitched_component = NULL;
	unsigned int stitched_component_size = 0;

	if (tss_response && plist_dict_get_item(tss_response, "ApImg4Ticket")) {
		/* stitch ApImg4Ticket into IMG4 file */
		img4_stitch_component(component_name, component_data, component_size, client->parameters, tss_response, &stitched_component, &stitched_component_size);
	} else {
		/* try to get blob for current component from tss response */
		if (tss_response && tss_response_get_blob_by_entry(tss_response, component_name, &component_blob) < 0) {
			debug("NOTE: No SHSH blob found for component %s\n", component_name);
		}

		if (component_blob != NULL) {
			if (img3_stitch_component(component_name, component_data, component_size, component_blob, 64, &stitched_component, &stitched_component_size) < 0) {
				error("ERROR: Unable to replace %s IMG3 signature\n", component_name);
				free(component_blob);
				return -1;
			}
		} else {
			info("Not personalizing component %s...\n", component_name);
			stitched_component = (unsigned char*)malloc(component_size);
			if (stitched_component) {
				stitched_component_size = component_size;
				memcpy(stitched_component, component_data, component_size);
			}
		}
	}
	free(component_blob);

	if (idevicerestore_keep_pers) {
		write_file(component_name, stitched_component, stitched_component_size);
	}

	*personalized_component = stitched_component;
	*personalized_component_size = stitched_component_size;
	return 0;
}

int build_manifest_check_compatibility(plist_t build_manifest, const char* product)
{
	int res = -1;
	plist_t node = plist_dict_get_item(build_manifest, "SupportedProductTypes");
	if (!node || (plist_get_node_type(node) != PLIST_ARRAY)) {
		debug("%s: ERROR: SupportedProductTypes key missing\n", __func__);
		debug("%s: WARNING: If attempting to install iPhoneOS 2.x, be advised that Restore.plist does not contain the", __func__);
		debug("%s: WARNING: key 'SupportedProductTypes'. Recommendation is to manually add it to the Restore.plist.", __func__);
		return -1;
	}
	uint32_t pc = plist_array_get_size(node);
	uint32_t i;
	for (i = 0; i < pc; i++) {
		plist_t prod = plist_array_get_item(node, i);
		if (plist_get_node_type(prod) == PLIST_STRING) {
			char *val = NULL;
			plist_get_string_val(prod, &val);
			if (val && (strcmp(val, product) == 0)) {
				res = 0;
				free(val);
				break;
			}
		}
	}
	return res;
}

void build_manifest_get_version_information(plist_t build_manifest, struct idevicerestore_client_t* client)
{
	plist_t node = NULL;
	client->version = NULL;
	client->build = NULL;

	node = plist_dict_get_item(build_manifest, "ProductVersion");
	if (!node || plist_get_node_type(node) != PLIST_STRING) {
		error("ERROR: Unable to find ProductVersion node\n");
		return;
	}
	plist_get_string_val(node, &client->version);

	node = plist_dict_get_item(build_manifest, "ProductBuildVersion");
	if (!node || plist_get_node_type(node) != PLIST_STRING) {
		error("ERROR: Unable to find ProductBuildVersion node\n");
		return;
	}
	plist_get_string_val(node, &client->build);

	client->build_major = strtoul(client->build, NULL, 10);
}

void build_identity_print_information(plist_t build_identity)
{
	char* value = NULL;
	plist_t info_node = NULL;
	plist_t node = NULL;

	info_node = plist_dict_get_item(build_identity, "Info");
	if (!info_node || plist_get_node_type(info_node) != PLIST_DICT) {
		error("ERROR: Unable to find Info node\n");
		return;
	}

	node = plist_dict_get_item(info_node, "Variant");
	if (!node || plist_get_node_type(node) != PLIST_STRING) {
		error("ERROR: Unable to find Variant node\n");
		return;
	}
	plist_get_string_val(node, &value);

	info("Variant: %s\n", value);

	if (strstr(value, RESTORE_VARIANT_UPGRADE_INSTALL))
		info("This restore will update the device without erasing user data.\n");
	else if (strstr(value, RESTORE_VARIANT_ERASE_INSTALL))
		info("This restore will erase all device data.\n");
	else
		info("Unknown Variant '%s'\n", value);

	free(value);

	info_node = NULL;
	node = NULL;
}

int build_identity_check_components_in_ipsw(plist_t build_identity, ipsw_archive_t ipsw)
{
	plist_t manifest_node = plist_dict_get_item(build_identity, "Manifest");
	if (!manifest_node || plist_get_node_type(manifest_node) != PLIST_DICT) {
		return -1;
	}
	int res = 0;
	plist_dict_iter iter = NULL;
	plist_dict_new_iter(manifest_node, &iter);
	plist_t node = NULL;
	char *key = NULL;
	do {
		node = NULL;
		key = NULL;
		plist_dict_next_item(manifest_node, iter, &key, &node);
		if (key && node) {
			plist_t path = plist_access_path(node, 2, "Info", "Path");
			if (path) {
				char *comp_path = NULL;
				plist_get_string_val(path, &comp_path);
				if (comp_path) {
					if (!ipsw_file_exists(ipsw, comp_path)) {
						error("ERROR: %s file %s not found in IPSW\n", key, comp_path);
						res = -1;
					}
					free(comp_path);
				}
			}
		}
		free(key);
	} while (node);
	return res;
}

int build_identity_has_component(plist_t build_identity, const char* component)
{
	plist_t manifest_node = plist_dict_get_item(build_identity, "Manifest");
	if (!manifest_node || plist_get_node_type(manifest_node) != PLIST_DICT) {
		return 0;
	}

	plist_t component_node = plist_dict_get_item(manifest_node, component);
	if (!component_node || plist_get_node_type(component_node) != PLIST_DICT) {
		return 0;
	}

	return 1;
}

int build_identity_get_component_path(plist_t build_identity, const char* component, char** path)
{
	char* filename = NULL;

	plist_t manifest_node = plist_dict_get_item(build_identity, "Manifest");
	if (!manifest_node || plist_get_node_type(manifest_node) != PLIST_DICT) {
		error("ERROR: Unable to find manifest node\n");
		if (filename)
			free(filename);
		return -1;
	}

	plist_t component_node = plist_dict_get_item(manifest_node, component);
	if (!component_node || plist_get_node_type(component_node) != PLIST_DICT) {
		error("ERROR: Unable to find component node for %s\n", component);
		if (filename)
			free(filename);
		return -1;
	}

	plist_t component_info_node = plist_dict_get_item(component_node, "Info");
	if (!component_info_node || plist_get_node_type(component_info_node) != PLIST_DICT) {
		error("ERROR: Unable to find component info node for %s\n", component);
		if (filename)
			free(filename);
		return -1;
	}

	plist_t component_info_path_node = plist_dict_get_item(component_info_node, "Path");
	if (!component_info_path_node || plist_get_node_type(component_info_path_node) != PLIST_STRING) {
		error("ERROR: Unable to find component info path node for %s\n", component);
		if (filename)
			free(filename);
		return -1;
	}
	plist_get_string_val(component_info_path_node, &filename);

	*path = filename;
	return 0;
}

const char* get_component_name(const char* filename)
{
	struct filename_component_map {
		const char *fnprefix;
		int matchlen;
		const char *compname;
	};
	struct filename_component_map fn_comp_map[] = {
		{ "LLB", 3, "LLB" },
		{ "iBoot", 5, "iBoot" },
		{ "DeviceTree", 10, "DeviceTree" },
		{ "applelogo", 9, "AppleLogo" },
		{ "liquiddetect", 12, "Liquid" },
		{ "lowpowermode", 12, "LowPowerWallet0" },
		{ "recoverymode", 12, "RecoveryMode" },
		{ "batterylow0", 11, "BatteryLow0" },
		{ "batterylow1", 11, "BatteryLow1" },
		{ "glyphcharging", 13, "BatteryCharging" },
		{ "glyphplugin", 11, "BatteryPlugin" },
		{ "batterycharging0", 16, "BatteryCharging0" },
		{ "batterycharging1", 16, "BatteryCharging1" },
		{ "batteryfull", 11, "BatteryFull" },
		{ "needservice", 11, "NeedService" },
		{ "SCAB", 4, "SCAB" },
		{ "sep-firmware", 12, "RestoreSEP" },
		{ NULL, 0, NULL }
	};
	int i = 0;
	while (fn_comp_map[i].fnprefix) {
		if (!strncmp(filename, fn_comp_map[i].fnprefix, fn_comp_map[i].matchlen)) {
			return fn_comp_map[i].compname;
		}
		i++;
	}
	error("WARNING: Unhandled component '%s'", filename);
	return NULL;
}
/*
 * ipsw.c
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



