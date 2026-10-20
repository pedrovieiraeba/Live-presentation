#include "cndi.h"

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

#define CNDI_RESOLVE(field, symbol)                                                    \
    do {                                                                               \
        *(void **)(&out->field) = dlsym(handle, symbol);                               \
        if (out->field == NULL) {                                                      \
            snprintf(error, error_length, "símbolo ausente na biblioteca NDI: %s", symbol); \
            dlclose(handle);                                                           \
            memset(out, 0, sizeof(*out));                                              \
            return 2;                                                                  \
        }                                                                              \
    } while (0)

int cndi_load(const char *path, cndi_lib *out, char *error, size_t error_length) {
    memset(out, 0, sizeof(*out));
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        const char *reason = dlerror();
        snprintf(error, error_length, "%s", reason ? reason : "dlopen falhou");
        return 1;
    }
    CNDI_RESOLVE(initialize, "NDIlib_initialize");
    CNDI_RESOLVE(destroy, "NDIlib_destroy");
    CNDI_RESOLVE(version, "NDIlib_version");
    CNDI_RESOLVE(find_create_v2, "NDIlib_find_create_v2");
    CNDI_RESOLVE(find_destroy, "NDIlib_find_destroy");
    CNDI_RESOLVE(find_get_current_sources, "NDIlib_find_get_current_sources");
    CNDI_RESOLVE(recv_create_v3, "NDIlib_recv_create_v3");
    CNDI_RESOLVE(recv_destroy, "NDIlib_recv_destroy");
    CNDI_RESOLVE(recv_capture_v2, "NDIlib_recv_capture_v2");
    CNDI_RESOLVE(recv_free_video_v2, "NDIlib_recv_free_video_v2");
    CNDI_RESOLVE(send_create, "NDIlib_send_create");
    CNDI_RESOLVE(send_destroy, "NDIlib_send_destroy");
    CNDI_RESOLVE(send_send_video_v2, "NDIlib_send_send_video_v2");
    CNDI_RESOLVE(send_get_no_connections, "NDIlib_send_get_no_connections");
    out->handle = handle;
    return 0;
}

void cndi_unload(cndi_lib *lib) {
    if (lib->handle != NULL) {
        dlclose(lib->handle);
    }
    memset(lib, 0, sizeof(*lib));
}

uint32_t cndi_fourcc(char a, char b, char c, char d) {
    return (uint32_t)(uint8_t)a | ((uint32_t)(uint8_t)b << 8) | ((uint32_t)(uint8_t)c << 16) |
           ((uint32_t)(uint8_t)d << 24);
}

size_t cndi_sizeof_video_frame(void) { return sizeof(cndi_video_frame_v2_t); }
size_t cndi_sizeof_recv_create(void) { return sizeof(cndi_recv_create_v3_t); }
