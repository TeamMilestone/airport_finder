/* A plain C API over the library build of the port (airport_finder_ext.rb),
   for hosts such as Python's ctypes. Every af_* entry returns a malloc'd
   JSON string, which the caller frees with af_free, or NULL after a Ruby
   raise, whose message af_error() then returns.

   Not reentrant: the Spinel runtime takes one call at a time, so a
   multithreaded host must serialize calls (the Python wrapper holds a lock). */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "airport_finder_ext.h"

/* The library is built with -fvisibility=hidden: these entries are all it
   exports. */
#define AF_API __attribute__((visibility("default")))

static int ready;
static char last_error[512];

/* Copies the entry's answer out of the GC heap, or records the raise. */
static char *finish(int raised, const char *cls, const char *msg, const char *out) {
  if (raised) {
    snprintf(last_error, sizeof last_error, "%s", msg && *msg ? msg : cls ? cls : "error");
    return NULL;
  }
  return strdup(out);
}

#define CALL(fn, ctx)                                          \
  const char *cls = NULL, *msg = NULL;                         \
  if (!ready) {                                                \
    af_ext_init();                                             \
    ready = 1;                                                 \
  }                                                            \
  int raised = af_ext_init_try(fn, &ctx, &cls, &msg);          \
  return finish(raised, cls, msg, ctx.out)

AF_API const char *af_error(void) { return last_error; }

AF_API void af_free(char *s) { free(s); }

typedef struct { double lat, lng; const char *out; } point_args;

static void do_find(void *p) {
  point_args *a = p;
  a->out = sp_AirportFinderExt_s_find(a->lat, a->lng);
}

AF_API char *af_find(double lat, double lng) {
  point_args ctx = {lat, lng, NULL};
  CALL(do_find, ctx);
}

static void do_country_at(void *p) {
  point_args *a = p;
  a->out = sp_AirportFinderExt_s_country_at(a->lat, a->lng);
}

AF_API char *af_country_at(double lat, double lng) {
  point_args ctx = {lat, lng, NULL};
  CALL(do_country_at, ctx);
}

typedef struct { const char *s; const char *out; } str_args;

static void do_airport(void *p) {
  str_args *a = p;
  a->out = sp_AirportFinderExt_s_airport(a->s);
}

AF_API char *af_airport(const char *iata) {
  str_args ctx = {iata, NULL};
  CALL(do_airport, ctx);
}

typedef struct { long long h; const char *s; const char *out; } set_args;

static void do_set_new(void *p) {
  set_args *a = p;
  a->out = sp_AirportFinderExt_s_set_new(a->s, a->h);
}

/* codes: `count` IATA codes joined by '\x1f' */
AF_API char *af_set_new(const char *codes, long long count) {
  set_args ctx = {count, codes, NULL};
  CALL(do_set_new, ctx);
}

static void do_set_free(void *p) {
  set_args *a = p;
  a->out = sp_AirportFinderExt_s_set_free(a->h);
}

AF_API char *af_set_free(long long h) {
  set_args ctx = {h, NULL, NULL};
  CALL(do_set_free, ctx);
}

static void do_set_size(void *p) {
  set_args *a = p;
  a->out = sp_AirportFinderExt_s_set_size(a->h);
}

AF_API char *af_set_size(long long h) {
  set_args ctx = {h, NULL, NULL};
  CALL(do_set_size, ctx);
}

static void do_set_include(void *p) {
  set_args *a = p;
  a->out = sp_AirportFinderExt_s_set_include(a->h, a->s);
}

AF_API char *af_set_include(long long h, const char *iata) {
  set_args ctx = {h, iata, NULL};
  CALL(do_set_include, ctx);
}

static void do_set_missing(void *p) {
  set_args *a = p;
  a->out = sp_AirportFinderExt_s_set_missing(a->h);
}

AF_API char *af_set_missing(long long h) {
  set_args ctx = {h, NULL, NULL};
  CALL(do_set_missing, ctx);
}

typedef struct {
  long long h;
  double lat, lng;
  const char *country;
  long long has_country;
  double max_km;
  long long has_max, limit;
  const char *out;
} nearest_args;

static void do_set_nearest(void *p) {
  nearest_args *a = p;
  a->out = sp_AirportFinderExt_s_set_nearest(a->h, a->lat, a->lng, a->country, a->has_country,
                                             a->max_km, a->has_max, a->limit);
}

AF_API char *af_set_nearest(long long h, double lat, double lng, const char *country, long long has_country,
                     double max_km, long long has_max, long long limit) {
  nearest_args ctx = {h, lat, lng, country, has_country, max_km, has_max, limit, NULL};
  CALL(do_set_nearest, ctx);
}

typedef struct {
  long long h;
  double lat, lng, foreign_max_km;
  long long has_max;
  const char *out;
} resolve_args;

static void do_set_resolve(void *p) {
  resolve_args *a = p;
  a->out = sp_AirportFinderExt_s_set_resolve(a->h, a->lat, a->lng, a->foreign_max_km, a->has_max);
}

AF_API char *af_set_resolve(long long h, double lat, double lng, double foreign_max_km, long long has_max) {
  resolve_args ctx = {h, lat, lng, foreign_max_km, has_max, NULL};
  CALL(do_set_resolve, ctx);
}
