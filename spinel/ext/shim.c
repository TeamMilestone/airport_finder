/* A plain C API over the library build of the port (airport_finder_ext.rb),
   for hosts such as Python's ctypes. Answers are numbers: an airport is its
   index in the embedded data (af_airport_record gives its fields), a country
   code an id (af_string gives the code). Answers with more than one value
   go to the buffers the host registered with af_buffers.

   After a Ruby raise, a number answer is AF_RAISED and a string answer
   NULL; af_error() then returns the message. String answers are malloc'd:
   the caller frees them with af_free.

   Not reentrant: the Spinel runtime takes one call at a time, so a
   multithreaded host must serialize calls (the Python wrapper holds a lock),
   and read the buffers before letting the next call in. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "airport_finder_ext.h"

/* The library is built with -fvisibility=hidden: these entries are all it
   exports. */
#define AF_API __attribute__((visibility("default")))

#define AF_RAISED (-2)

static int ready;
static char last_error[512];
static long long *out_index;
static double *out_km;
static long long out_cap;

/* Runs fn(ctx) as an entry call; 1 after a Ruby raise, whose message it
   records. */
static int run(void (*fn)(void *), void *ctx) {
  const char *cls = NULL, *msg = NULL;
  if (!ready) {
    af_ext_init();
    ready = 1;
  }
  if (!af_ext_init_try(fn, ctx, &cls, &msg)) return 0;
  snprintf(last_error, sizeof last_error, "%s", msg && *msg ? msg : cls ? cls : "error");
  return 1;
}

/* Copies the entry's extra values out to the host's buffers. */
static void copy_out(long long indices, long long kms) {
  for (long long k = 0; k < indices && k < out_cap; k++) out_index[k] = sp_AirportFinderExt_s_out_index(k);
  for (long long k = 0; k < kms && k < out_cap; k++) out_km[k] = sp_AirportFinderExt_s_out_km(k);
}

AF_API const char *af_error(void) { return last_error; }

AF_API void af_free(char *s) { free(s); }

/* Where af_set_nearest, af_set_resolve and af_airport_record put their
   extra values: `cap` of each, at least 3. */
AF_API void af_buffers(long long *index, double *km, long long cap) {
  out_index = index;
  out_km = km;
  out_cap = cap;
}

typedef struct { double lat, lng; long long out; } point_args;

static void do_find(void *p) {
  point_args *a = p;
  a->out = sp_AirportFinderExt_s_find(a->lat, a->lng);
}

/* find_nearest_airport's airport; AF_RAISED with its error. */
AF_API long long af_find(double lat, double lng) {
  point_args a = {lat, lng, 0};
  return run(do_find, &a) ? AF_RAISED : a.out;
}

static void do_country_at(void *p) {
  point_args *a = p;
  a->out = sp_AirportFinderExt_s_country_at(a->lat, a->lng);
}

/* The country code's id, or -1 for none. */
AF_API long long af_country_at(double lat, double lng) {
  point_args a = {lat, lng, 0};
  return run(do_country_at, &a) ? AF_RAISED : a.out;
}

typedef struct { long long n; const char *s; long long out; const char *str; } scalar_args;

static void do_string(void *p) {
  scalar_args *a = p;
  a->str = sp_AirportFinderExt_s_string(a->n);
}

AF_API char *af_string(long long id) {
  scalar_args a = {id, NULL, 0, NULL};
  return run(do_string, &a) ? NULL : strdup(a.str);
}

static void do_airport(void *p) {
  scalar_args *a = p;
  a->out = sp_AirportFinderExt_s_airport(a->s);
}

/* The airport with this IATA code, or -1. */
AF_API long long af_airport(const char *iata) {
  scalar_args a = {0, iata, 0, NULL};
  return run(do_airport, &a) ? AF_RAISED : a.out;
}

static void do_airport_record(void *p) {
  scalar_args *a = p;
  a->str = sp_AirportFinderExt_s_airport_record(a->n);
  copy_out(0, 2);
}

/* Airport i's code, iata, name, airport_name, city and country, joined by
   '\x1f'; its lat and lng go to the km buffer. */
AF_API char *af_airport_record(long long i) {
  scalar_args a = {i, NULL, 0, NULL};
  return run(do_airport_record, &a) ? NULL : strdup(a.str);
}

typedef struct { long long h; const char *s; long long out; const char *str; } set_args;

static void do_set_new(void *p) {
  set_args *a = p;
  a->out = sp_AirportFinderExt_s_set_new(a->s, a->h);
}

/* codes: `count` IATA codes joined by '\x1f'. The set's handle. */
AF_API long long af_set_new(const char *codes, long long count) {
  set_args a = {count, codes, 0, NULL};
  return run(do_set_new, &a) ? AF_RAISED : a.out;
}

static void do_set_free(void *p) {
  set_args *a = p;
  a->out = sp_AirportFinderExt_s_set_free(a->h);
}

AF_API long long af_set_free(long long h) {
  set_args a = {h, NULL, 0, NULL};
  return run(do_set_free, &a) ? AF_RAISED : a.out;
}

static void do_set_size(void *p) {
  set_args *a = p;
  a->out = sp_AirportFinderExt_s_set_size(a->h);
}

AF_API long long af_set_size(long long h) {
  set_args a = {h, NULL, 0, NULL};
  return run(do_set_size, &a) ? AF_RAISED : a.out;
}

static void do_set_include(void *p) {
  set_args *a = p;
  a->out = sp_AirportFinderExt_s_set_include(a->h, a->s);
}

/* 1 or 0 */
AF_API long long af_set_include(long long h, const char *iata) {
  set_args a = {h, iata, 0, NULL};
  return run(do_set_include, &a) ? AF_RAISED : a.out;
}

static void do_set_missing(void *p) {
  set_args *a = p;
  a->str = sp_AirportFinderExt_s_set_missing(a->h);
}

/* The codes the data does not know, each followed by '\x1f'. */
AF_API char *af_set_missing(long long h) {
  set_args a = {h, NULL, 0, NULL};
  return run(do_set_missing, &a) ? NULL : strdup(a.str);
}

typedef struct {
  long long h;
  double lat, lng;
  const char *country;
  long long has_country;
  double max_km;
  long long has_max, limit, out;
} nearest_args;

static void do_set_nearest(void *p) {
  nearest_args *a = p;
  a->out = sp_AirportFinderExt_s_set_nearest(a->h, a->lat, a->lng, a->country, a->has_country,
                                             a->max_km, a->has_max, a->limit);
  copy_out(a->out, a->out);
}

/* How many airports AirportSet#nearest found: the k-th goes to index[k],
   its distance to km[k]. The buffers must hold min(limit, set size). */
AF_API long long af_set_nearest(long long h, double lat, double lng, const char *country,
                                long long has_country, double max_km, long long has_max, long long limit) {
  nearest_args a = {h, lat, lng, country, has_country, max_km, has_max, limit, 0};
  return run(do_set_nearest, &a) ? AF_RAISED : a.out;
}

typedef struct {
  long long h;
  double lat, lng, foreign_max_km;
  long long has_max, out;
} resolve_args;

static void do_set_resolve(void *p) {
  resolve_args *a = p;
  a->out = sp_AirportFinderExt_s_set_resolve(a->h, a->lat, a->lng, a->foreign_max_km, a->has_max);
  copy_out(3, 1);
}

/* AirportSet#resolve's airport, or -1 for none. km[0] is its distance,
   index[1] the resolution (0 nearest, 1 same_country, 2 nearby_foreign)
   and index[2] find_nearest_airport's airport. */
AF_API long long af_set_resolve(long long h, double lat, double lng, double foreign_max_km, long long has_max) {
  resolve_args a = {h, lat, lng, foreign_max_km, has_max, 0};
  return run(do_set_resolve, &a) ? AF_RAISED : a.out;
}
