#ifndef RIBBON_CORE_H
#define RIBBON_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RibbonEngine RibbonEngine;

/* config_json: NULL or "" -> defaults. Invalid config also falls back to defaults. */
RibbonEngine *ribbon_engine_new(const char *config_json);
void          ribbon_engine_free(RibbonEngine *);
/* Returns a Plan JSON string; never NULL for valid arguments. Free with ribbon_string_free. */
char         *ribbon_engine_handle(RibbonEngine *, const char *event_json);
void          ribbon_string_free(char *);
/* "plus" or "free": which edition this core was built as. Static string, never freed. */
const char   *ribbon_core_edition(void);

#ifdef __cplusplus
}
#endif

#endif /* RIBBON_CORE_H */
