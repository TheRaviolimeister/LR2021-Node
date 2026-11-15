/* Grid A* for the carrier board router (two layers, 8 directions, bend and via costs).
 *
 * State = (layer, row, column, direction of the last step); direction 8 = no step yet (pad / via).
 * Turns of 45 degrees cost `bend45`, 90 degrees `bend90`, sharper turns are not allowed, so the
 * tracks come out straight with chamfered corners. Build: gcc -O2 -shared -fPIC -o astar.so astar.c
 */
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static const int DI[8] = {1, 1, 0, -1, -1, -1, 0, 1};
static const int DJ[8] = {0, 1, 1, 1, 0, -1, -1, -1};

typedef struct { float f; int32_t s; } item;

static item *heap = NULL;
static long hcap = 0, hn = 0;

static void hpush(float f, int32_t s) {
    if (hn >= hcap) {
        hcap = hcap ? hcap * 2 : (1 << 20);
        heap = (item *)realloc(heap, hcap * sizeof(item));
    }
    long k = hn++;
    while (k > 0) {
        long p = (k - 1) / 2;
        if (heap[p].f <= f) break;
        heap[k] = heap[p];
        k = p;
    }
    heap[k].f = f;
    heap[k].s = s;
}

static item hpop(void) {
    item top = heap[0], last = heap[--hn];
    long k = 0;
    for (;;) {
        long c = 2 * k + 1;
        if (c >= hn) break;
        if (c + 1 < hn && heap[c + 1].f < heap[c].f) c++;
        if (heap[c].f >= last.f) break;
        heap[k] = heap[c];
        k = c;
    }
    heap[k] = last;
    return top;
}

static float *g = NULL;
static int32_t *par = NULL;
static uint32_t *stamp = NULL;
static uint32_t cur = 0;
static long nstates = 0;

/* blk[2*ny*nx], viaok[ny*nx], src[2*ny*nx], tgt[2*ny*nx]: uint8 masks.
 * cost[0..5]: top orth, top diag, bottom orth, bottom diag (per unit length), bend45, bend90
 * cost[6]: via, cost[7]: heuristic weight. pref: per layer extra factor for horizontal (0) / vertical (1)
 * out: path as (layer, row, col) triples from source to target; returns the number of points or -1. */
int astar(int nx, int ny, const uint8_t *blk, const uint8_t *viaok, const uint8_t *src, const uint8_t *tgt,
          const double *cost, const double *pref, double tx, double ty, long max_exp, int32_t *out, int out_cap) {
    long ncell = (long)nx * ny;
    long need = 2 * ncell * 9;
    if (need != nstates) {
        free(g); free(par); free(stamp);
        g = (float *)malloc(need * sizeof(float));
        par = (int32_t *)malloc(need * sizeof(int32_t));
        stamp = (uint32_t *)calloc(need, sizeof(uint32_t));
        nstates = need;
        cur = 0;
    }
    cur += 2;   /* stamp cur = seen, cur+1 = closed */
    if (cur > 0xFFFFFFF0u) { memset(stamp, 0, need * sizeof(uint32_t)); cur = 2; }
    hn = 0;
    double w = cost[7];
#define H(i, j) ((float)(w * (fabs((i) - tx) > fabs((j) - ty) ? \
        fabs((i) - tx) + 0.41421356 * fabs((j) - ty) : fabs((j) - ty) + 0.41421356 * fabs((i) - tx))))
    for (int L = 0; L < 2; L++)
        for (long c = 0; c < ncell; c++)
            if (src[L * ncell + c]) {
                long s = ((L * ncell) + c) * 9 + 8;
                g[s] = 0; par[s] = -1; stamp[s] = cur;
                hpush(H(c % nx, c / nx), (int32_t)s);
            }
    long n = 0;
    while (hn > 0) {
        item it = hpop();
        long s = it.s;
        if (stamp[s] == cur + 1) continue;
        stamp[s] = cur + 1;
        int d = s % 9;
        long cell = s / 9;
        int L = cell / ncell;
        long c = cell % ncell;
        int i = c % nx, j = c / nx;
        if (tgt[L * ncell + c]) {
            int k = 0;
            long t = s;
            while (t >= 0 && k < out_cap) {
                long cc = t / 9;
                out[3 * k] = cc / ncell;
                out[3 * k + 1] = (cc % ncell) / nx;
                out[3 * k + 2] = (cc % ncell) % nx;
                k++;
                t = par[t];
            }
            return k;
        }
        if (++n > max_exp) return -1;
        float gs = g[s];
        for (int nd = 0; nd < 8; nd++) {
            double extra = 0;
            if (d < 8) {
                int t = abs(nd - d);
                if (t > 4) t = 8 - t;
                if (t > 2) continue;
                if (t == 1) extra = cost[4];
                if (t == 2) extra = cost[5];
            }
            int ni = i + DI[nd], nj = j + DJ[nd];
            if (ni < 0 || nj < 0 || ni >= nx || nj >= ny) continue;
            long nc = (long)nj * nx + ni;
            if (blk[L * ncell + nc]) continue;
            int diag = DI[nd] && DJ[nd];
            if (diag && (blk[L * ncell + (long)j * nx + ni] || blk[L * ncell + (long)nj * nx + i])) continue;
            double step = diag ? cost[2 * L + 1] * 1.41421356 : cost[2 * L] * (DI[nd] ? pref[2 * L] : pref[2 * L + 1]);
            float ng = (float)(gs + step + extra);
            long ns = ((L * ncell) + nc) * 9 + nd;
            if (stamp[ns] >= cur && ng >= g[ns]) continue;
            if (stamp[ns] == cur + 1) continue;
            g[ns] = ng; par[ns] = (int32_t)s; stamp[ns] = cur;
            hpush(ng + H(ni, nj), (int32_t)ns);
        }
        if (viaok[c]) {
            int nl = 1 - L;
            long ns = ((nl * ncell) + c) * 9 + 8;
            float ng = (float)(gs + cost[6]);
            if (!(stamp[ns] >= cur && ng >= g[ns]) && stamp[ns] != cur + 1) {
                g[ns] = ng; par[ns] = (int32_t)s; stamp[ns] = cur;
                hpush(ng + H(i, j), (int32_t)ns);
            }
        }
    }
    return -1;
}
