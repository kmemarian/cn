#include <assert.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <bennet-exp/internals/rand.h>
#include <bennet-exp/internals/size.h>

// Mersenne twister from https://doi.org/10.1145/369534.369540

/* Period parameters */
#define NN 312
#define M0 63
#define M1 151
#define M2 224
/* Constant vector a */
#define MATRIX_A 0xB3815B624FC82E2FULL
/* Most significant 33 bits */
#define UMASK 0xFFFFFFFF80000000ULL
/* Least significant 31 bits */
#define LMASK 0x7FFFFFFFULL

/* Tempering parameters */
#define MASK_B 0x599CFCBFCA660000ULL
#define MASK_C 0xFFFAAFFE00000000ULL
#define UU     26
#define SS     17
#define TT     33
#define LL     39

/* The array for the state vector */
static unsigned long long mt[NN];
/* mti55NN11 means mt[NN] is not initialized */
static int mti = NN + 1;

void sgenrand(uint64_t seed) {
  uint64_t ux, lx;
  for (mti = 0; mti < NN; mti++) {
    ux = seed & 0xFFFFFFFF00000000ULL;
    seed = 2862933555777941757ULL * seed + 1ULL;
    lx = seed >> 32;
    seed = 2862933555777941757ULL * seed + 1ULL;
    mt[mti] = ux | lx;
  }
}

uint64_t genrand(void) {
  int32_t i;
  uint64_t x;
  static unsigned long long mag01[2] = {0ULL, MATRIX_A};

  if (mti >= NN) { /* generate NN words at one time */
    /* if sgenrand() has not been called, */
    /* a default initial seed is used */
    if (mti == NN + 1)
      sgenrand(0xDEADCAFE);

    for (i = 0; i < NN - M2; i++) {
      x = (mt[i] & UMASK) | (mt[i + 1] & LMASK);
      mt[i] = (x >> 1) ^ mag01[(int)(x & 1ULL)];
      mt[i] ^= mt[i + M0] ^ mt[i + M1] ^ mt[i + M2];
    }
    for (; i < NN - M1; i++) {
      x = (mt[i] & UMASK) | (mt[i + 1] & LMASK);
      mt[i] = (x >> 1) ^ mag01[(int)(x & 1ULL)];
      mt[i] ^= mt[i + M0] ^ mt[i + M1] ^ mt[i + M2 - NN];
    }
    for (; i < NN - M0; i++) {
      x = (mt[i] & UMASK) | (mt[i + 1] & LMASK);
      mt[i] = (x >> 1) ^ mag01[(int)(x & 1ULL)];
      mt[i] ^= mt[i + M0] ^ mt[i + M1 - NN] ^ mt[i + M2 - NN];
    }
    for (; i < NN - 1; i++) {
      x = (mt[i] & UMASK) | (mt[i + 1] & LMASK);
      mt[i] = (x >> 1) ^ mag01[(int)(x & 1ULL)];
      mt[i] ^= mt[i + M0 - NN] ^ mt[i + M1 - NN] ^ mt[i + M2 - NN];
    }
    x = (mt[NN - 1] & UMASK) | (mt[0] & LMASK);
    mt[NN - 1] = (x >> 1) ^ mag01[(int)(x & 1ULL)];
    mt[NN - 1] ^= mt[M0 - 1] ^ mt[M1 - 1] ^ mt[M2 - 1];

    mti = 0;
  }

  x = mt[mti++];
  x ^= (x >> UU);
  x ^= (x << SS) & MASK_B;
  x ^= (x << TT) & MASK_C;
  x ^= (x >> LL);

  return x;
}

/////////////////////////////
// End of Mersenne twister //
/////////////////////////////

// Sized generation according to Lemire: https://doi.org/10.1145/3230636
#define UNSIGNED_GEN(sm, lg)                                                             \
  uint##sm##_t bennet_uniform_uint##sm##_t(uint##sm##_t s) {                             \
    uint##sm##_t x = bennet_rand();                                                      \
    if (s == 0) {                                                                        \
      return x;                                                                          \
    }                                                                                    \
                                                                                         \
    uint##lg##_t m = (uint##lg##_t)x * (uint##lg##_t)s;                                  \
    uint##sm##_t l = m; /* m % pow(2, sm) */                                             \
    if (l < s) {                                                                         \
      uint##lg##_t t = (UINT##sm##_MAX - (s - 1)) % s;                                   \
      while (l < t) {                                                                    \
        x = bennet_rand();                                                               \
        m = x * s;                                                                       \
        l = m; /* m % pow(2, sm) */                                                      \
      }                                                                                  \
    }                                                                                    \
    return m >> sm;                                                                      \
  }

UNSIGNED_GEN(8, 16);
UNSIGNED_GEN(16, 32);
UNSIGNED_GEN(32, 64);

// OpenJDK 9 implementation, according to the definition in Lemire.
uint64_t bennet_uniform_uint64_t(uint64_t s) {
  uint64_t x = bennet_rand();
  if (s == 0) {
    return x;
  }

  uint64_t r = x % s;
  while (x - r > UINT64_MAX - (s - 1)) {
    x = bennet_rand();
    r = x % s;
  }
  return r;
}

#define SIGNED_GEN(sm)                                                                   \
  int##sm##_t bennet_uniform_int##sm##_t(uint##sm##_t s) {                               \
    if (s == 0) {                                                                        \
      return bennet_uniform_uint##sm##_t(0);                                             \
    }                                                                                    \
    return bennet_uniform_uint##sm##_t(2 * s - 1) - (s - 1);                             \
  }

SIGNED_GEN(8);
SIGNED_GEN(16);
SIGNED_GEN(32);
SIGNED_GEN(64);

#define SIZED_GEN(sm)                                                                    \
  uint##sm##_t bennet_uniform_uint##sm##_t_sized(uint##sm##_t s) {                       \
    size_t sz = bennet_get_size();                                                       \
    if (s != 0 && s < sz) {                                                              \
      sz = s;                                                                            \
    }                                                                                    \
                                                                                         \
    if (sz <= 8 * sizeof(size_t)) {                                                      \
      size_t extremes_likelihood = 1 << (sz / 2 + 1);                                    \
      if (!bennet_uniform_uint64_t(extremes_likelihood)) {                               \
        return (s == 0) ? UINT##sm##_MAX : (s - 1);                                      \
      }                                                                                  \
    }                                                                                    \
                                                                                         \
    return bennet_uniform_uint##sm##_t(sz);                                              \
  }                                                                                      \
  int##sm##_t bennet_uniform_int##sm##_t_sized(uint##sm##_t s) {                         \
    size_t sz = bennet_get_size();                                                       \
    if (s != 0 && s < sz) {                                                              \
      sz = s;                                                                            \
    }                                                                                    \
                                                                                         \
    if (sz <= 8 * sizeof(size_t)) {                                                      \
      size_t extremes_likelihood = 1 << (sz / 2 + 1);                                    \
      if (!bennet_uniform_uint64_t(extremes_likelihood)) {                               \
        switch (bennet_uniform_uint8_t(2)) {                                             \
          case 0:                                                                        \
            return (s == 0) ? INT##sm##_MIN : -(s - 1);                                  \
          case 1:                                                                        \
            return (s == 0) ? INT##sm##_MAX : (s - 1);                                   \
          default:                                                                       \
            assert(0);                                                                   \
        }                                                                                \
      }                                                                                  \
    }                                                                                    \
                                                                                         \
    return bennet_uniform_int##sm##_t(sz);                                               \
  }

SIZED_GEN(8);
SIZED_GEN(16);
SIZED_GEN(32);
SIZED_GEN(64);

#define RANGE_GEN(sm)                                                                    \
  uint##sm##_t bennet_range_uint##sm##_t(uint##sm##_t min, uint##sm##_t max) {           \
    if (min == max) {                                                                    \
      return min;                                                                        \
    }                                                                                    \
    if (min == 0 && max == UINT##sm##_MAX) {                                             \
      return bennet_uniform_uint##sm##_t_sized(bennet_get_size());                       \
    }                                                                                    \
                                                                                         \
    size_t sz = bennet_get_size();                                                       \
    size_t width = max - min + 1;                                                        \
    if (width > sz) {                                                                    \
      width = sz;                                                                        \
    }                                                                                    \
    return bennet_uniform_uint##sm##_t_sized(width) + min;                               \
  }                                                                                      \
  int##sm##_t bennet_range_int##sm##_t(int##sm##_t min, int##sm##_t max) {               \
    if (min == max) {                                                                    \
      return min;                                                                        \
    }                                                                                    \
    if (min == INT##sm##_MIN && max == INT##sm##_MAX) {                                  \
      return bennet_uniform_int##sm##_t_sized(bennet_get_size());                        \
    }                                                                                    \
                                                                                         \
    min -= (max == INT##sm##_MAX);                                                       \
                                                                                         \
    int32_t sz = (int32_t)bennet_get_size();                                             \
                                                                                         \
    /* Shifts the range bounds to be centered around zero, */                            \
    /* but ensure `max - min` <= `2 * sz` */                                             \
    if (min <= -sz + 1) {                                                                \
      if (max >= sz) {                                                                   \
        min = -sz + 1;                                                                   \
        max = sz;                                                                        \
      } else {                                                                           \
        int32_t excess = (sz - max);                                                     \
        if (min < -sz + 1 - excess) {                                                    \
          min = -sz + 1 - excess;                                                        \
        }                                                                                \
      }                                                                                  \
    } else {                                                                             \
      int32_t excess = min - (-sz + 1);                                                  \
      if (max > sz + excess) {                                                           \
        max = sz + excess;                                                               \
      }                                                                                  \
    }                                                                                    \
                                                                                         \
    return bennet_uniform_uint##sm##_t_sized(max - min) + min + (max == INT##sm##_MAX);  \
  }

RANGE_GEN(8);
RANGE_GEN(16);
RANGE_GEN(32);
RANGE_GEN(64);

#define INEQ_GEN(sm)                                                                     \
  uint##sm##_t bennet_le_uint##sm##_t(uint##sm##_t max) {                                \
    if (max == UINT##sm##_MAX) {                                                         \
      return bennet_uniform_uint##sm##_t_sized(bennet_get_size());                       \
    }                                                                                    \
    return bennet_uniform_uint##sm##_t_sized(max + 1);                                   \
  }                                                                                      \
  int##sm##_t bennet_le_int##sm##_t(int##sm##_t max) {                                   \
    if (max == INT##sm##_MAX) {                                                          \
      return bennet_uniform_int##sm##_t_sized(bennet_get_size());                        \
    }                                                                                    \
    return bennet_range_int##sm##_t(INT##sm##_MIN, max);                                 \
  }                                                                                      \
  uint##sm##_t bennet_ge_uint##sm##_t(uint##sm##_t min) {                                \
    if (min == 0) {                                                                      \
      return bennet_uniform_uint##sm##_t_sized(bennet_get_size());                       \
    }                                                                                    \
    return bennet_range_uint##sm##_t(min, UINT##sm##_MAX);                               \
  }                                                                                      \
  int##sm##_t bennet_ge_int##sm##_t(int##sm##_t min) {                                   \
    if (min == INT##sm##_MIN) {                                                          \
      return bennet_uniform_int##sm##_t_sized(bennet_get_size());                        \
    }                                                                                    \
    return bennet_range_int##sm##_t(min, INT##sm##_MAX);                                 \
  }

INEQ_GEN(8);
INEQ_GEN(16);
INEQ_GEN(32);
INEQ_GEN(64);

#define MULT_RANGE_GEN(sm)                                                               \
  uint##sm##_t bennet_mult_range_uint##sm##_t(                                           \
      uint##sm##_t mul, uint##sm##_t min, uint##sm##_t max) {                            \
    assert(mul != 0);                                                                    \
                                                                                         \
    if (mul == 1) {                                                                      \
      return bennet_uniform_uint##sm##_t_sized(bennet_get_size());                       \
    }                                                                                    \
                                                                                         \
    uint##sm##_t x = bennet_range_uint##sm##_t(min / mul, max / mul + (max % mul != 0)); \
    return x * mul;                                                                      \
  }                                                                                      \
  int##sm##_t bennet_mult_range_int##sm##_t(                                             \
      int##sm##_t mul, int##sm##_t min, int##sm##_t max) {                               \
    assert(mul != 0);                                                                    \
                                                                                         \
    if (mul == 1) {                                                                      \
      return bennet_uniform_int##sm##_t_sized(bennet_get_size());                        \
    }                                                                                    \
                                                                                         \
    int##sm##_t x = bennet_range_int##sm##_t(min / mul, max / mul + (max % mul != 0));   \
                                                                                         \
    return x * mul;                                                                      \
  }

MULT_RANGE_GEN(8);
MULT_RANGE_GEN(16);
MULT_RANGE_GEN(32);
MULT_RANGE_GEN(64);

#define MULT_GEN(sm)                                                                     \
  uint##sm##_t bennet_mult_uint##sm##_t(uint##sm##_t mul) {                              \
    return bennet_mult_range_uint##sm##_t(mul, 0, UINT##sm##_MAX);                       \
  }                                                                                      \
  int##sm##_t bennet_mult_int##sm##_t(int##sm##_t mul) {                                 \
    return bennet_mult_range_int##sm##_t(mul, INT##sm##_MIN, INT##sm##_MAX);             \
  }

MULT_GEN(8);
MULT_GEN(16);
MULT_GEN(32);
MULT_GEN(64);

void bennet_shuffle(void* arr, size_t len, size_t size) {
  // byte size is implementation-defined (6.5.3.4, bullet 2)
  // but `sizeof(char) == 1` is guaranteed.
  char tmp[size];

  for (int i = len - 1; i >= 0; i--) {
    uint8_t j = bennet_range_uint8_t(0, i + 1);
    memcpy(tmp, arr + i * size, size);
    memcpy(arr + i * size, arr + j * size, size);
    memcpy(arr + j * size, tmp, size);
  }
}

void bennet_split(size_t n, size_t* arr[], size_t len) {
  if (len == 1) {
    *(arr[0]) = n;
    return;
  }

  if (len == 2) {
    *(arr[0]) = (size_t)bennet_range_uint64_t(0, n + 1);
    *(arr[1]) = n - *(arr[0]);
    return;
  }

  int used = 0;
  for (int i = 0; i < len - 1; i++) {
    int left = n - (len - i) + 1 - used;
    size_t rnd = (size_t)bennet_range_uint64_t(1, left + 1);
    *(arr[i]) = rnd;
    used += rnd;
  }
  *(arr[len - 1]) = n - 1 - used;

  bennet_shuffle(&arr, len, sizeof(size_t*));
}

static struct choice_list* choice_history = 0;

void bennet_srand(uint64_t seed) {
  sgenrand(seed);

  while (choice_history != NULL) {
    struct choice_list* tmp = choice_history;
    choice_history = choice_history->next;
    free(tmp);
  }
}

static bool injecting = false;

void bennet_rand_start_injection(void) {
  assert(!injecting);
  injecting = true;
}

void bennet_rand_end_injection(void) {
  assert(injecting);
  injecting = false;
}

uint64_t bennet_rand(void) {
  if (!injecting && choice_history != NULL && choice_history->next != NULL) {
    choice_history = choice_history->next;
    return choice_history->choice;
  }

  uint64_t choice = genrand();

  struct choice_list* new_node = malloc(sizeof(struct choice_list));
  *new_node =
      (struct choice_list){.choice = choice, .next = NULL, .prev = choice_history};

  if (choice_history != NULL) {
    if (choice_history->next != NULL) {
      assert(injecting);
      new_node->next = choice_history->next;
      choice_history->next->prev = new_node;
    }

    choice_history->next = new_node;
  }

  choice_history = new_node;

  return choice;
}

bennet_rand_checkpoint bennet_rand_save(void) {
  assert(choice_history != NULL);
  return choice_history;
}

void bennet_rand_restore(bennet_rand_checkpoint checkpoint) {
  choice_history = checkpoint;
}

void free_list(struct choice_list* curr) {
  while (curr != NULL) {
    struct choice_list* tmp = curr;
    curr = curr->next;
    free(tmp);
  }
}

void bennet_rand_replace(bennet_rand_checkpoint checkpoint) {
  bennet_rand_restore(checkpoint);
  free_list(choice_history->next);
  choice_history->next = 0;
}

void bennet_rand_skip_to(bennet_rand_checkpoint checkpoint) {
  assert(choice_history != NULL);

  if (checkpoint->prev) {
    checkpoint->prev->next = NULL;
  }

  // free_list(choice_history->next);
  checkpoint->prev = choice_history;
  choice_history->next = checkpoint;

  choice_history = checkpoint;
}

char* bennet_rand_to_str(bennet_rand_checkpoint checkpoint) {
  size_t bytes = 1;

  struct choice_list* curr = (struct choice_list*)checkpoint;
  while (curr != NULL) {
    bytes += 20;

    curr = curr->next;
  }

  curr = (struct choice_list*)checkpoint;
  char* buf = malloc(bytes);
  buf[0] = '\0';

  if (curr != NULL) {
    curr = curr->next;
  }

  if (curr != NULL) {
    snprintf(buf, bytes, "%" PRIu64, curr->choice);

    curr = curr->next;
  }

  while (curr != NULL) {
    char* tmp = malloc(21);
    snprintf(tmp, 21, ", %" PRIu64, curr->choice);
    strcat(buf, tmp);
    free(tmp);

    curr = curr->next;
  }

  return buf;
}
