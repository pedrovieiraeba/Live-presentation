#ifndef CNDI_H
#define CNDI_H

// Ponte mínima para o NDI SDK, carregado dinamicamente (dlopen) em tempo de
// execução. O SDK NÃO é distribuído com este projeto: o usuário instala e aceita
// a licença da NDI. Sem a biblioteca, o app funciona e informa a ausência.
//
// As estruturas abaixo foram escritas à mão para reproduzir a ABI pública do
// NDI SDK (v5/v6) — não são cópia dos headers oficiais. ATENÇÃO: conferir campo
// a campo com Processing.NDI.Find.h / Recv.h / Send.h / structs.h do SDK
// instalado antes de uso em produção (ver docs/decisions/0006).

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char *p_ndi_name;
    const char *p_url_address;
} cndi_source_t;

typedef struct {
    bool show_local_sources;
    const char *p_groups;
    const char *p_extra_ips;
} cndi_find_create_t;

// Valores de NDIlib_recv_color_format_e / NDIlib_recv_bandwidth_e usados aqui.
enum {
    CNDI_RECV_COLOR_FORMAT_BGRX_BGRA = 0,
    CNDI_RECV_BANDWIDTH_LOWEST = 0,
    CNDI_RECV_BANDWIDTH_HIGHEST = 100,
};

typedef struct {
    cndi_source_t source_to_connect_to;
    int32_t color_format;
    int32_t bandwidth;
    bool allow_video_fields;
    const char *p_ndi_recv_name;
} cndi_recv_create_v3_t;

// Valores de NDIlib_frame_type_e.
enum {
    CNDI_FRAME_TYPE_NONE = 0,
    CNDI_FRAME_TYPE_VIDEO = 1,
    CNDI_FRAME_TYPE_AUDIO = 2,
    CNDI_FRAME_TYPE_METADATA = 3,
    CNDI_FRAME_TYPE_ERROR = 4,
    CNDI_FRAME_TYPE_STATUS_CHANGE = 100,
};

// NDIlib_frame_format_type_progressive.
enum { CNDI_FRAME_FORMAT_PROGRESSIVE = 1 };

typedef struct {
    int32_t xres;
    int32_t yres;
    uint32_t four_cc;
    int32_t frame_rate_N;
    int32_t frame_rate_D;
    float picture_aspect_ratio;
    int32_t frame_format_type;
    int64_t timecode;
    uint8_t *p_data;
    int32_t line_stride_in_bytes;
    const char *p_metadata;
    int64_t timestamp;
} cndi_video_frame_v2_t;

typedef struct {
    const char *p_ndi_name;
    const char *p_groups;
    bool clock_video;
    bool clock_audio;
} cndi_send_create_t;

/// Tabela de funções resolvidas na biblioteca carregada.
typedef struct {
    void *handle;
    bool (*initialize)(void);
    void (*destroy)(void);
    const char *(*version)(void);
    void *(*find_create_v2)(const cndi_find_create_t *);
    void (*find_destroy)(void *);
    const cndi_source_t *(*find_get_current_sources)(void *, uint32_t *);
    void *(*recv_create_v3)(const cndi_recv_create_v3_t *);
    void (*recv_destroy)(void *);
    int32_t (*recv_capture_v2)(void *, cndi_video_frame_v2_t *, void *, void *, uint32_t);
    void (*recv_free_video_v2)(void *, const cndi_video_frame_v2_t *);
    void *(*send_create)(const cndi_send_create_t *);
    void (*send_destroy)(void *);
    void (*send_send_video_v2)(void *, const cndi_video_frame_v2_t *);
    int32_t (*send_get_no_connections)(void *, uint32_t);
} cndi_lib;

/// Carrega a biblioteca em `path` e resolve todos os símbolos.
/// Retorna 0 em sucesso; em erro, escreve a causa em `error` e retorna != 0.
int cndi_load(const char *path, cndi_lib *out, char *error, size_t error_length);

void cndi_unload(cndi_lib *lib);

/// FourCC no formato do NDI (little-endian: 'B','G','R','A' → BGRA).
uint32_t cndi_fourcc(char a, char b, char c, char d);

/// Tamanhos das estruturas, para testes de layout.
size_t cndi_sizeof_video_frame(void);
size_t cndi_sizeof_recv_create(void);

#ifdef __cplusplus
}
#endif

#endif
