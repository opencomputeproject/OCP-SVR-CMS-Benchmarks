/*-----------------------------------------------------------------------*/
/* Program: STREAM                                                       */
/* Revision: $Id: stream.c,v 5.10 2013/01/17 16:01:06 mccalpin Exp mccalpin $ */
/* Original code developed by John D. McCalpin                           */
/* Programmers: John D. McCalpin                                         */
/*              Joe R. Zagar                                             */
/*                                                                       */
/* This program measures memory transfer rates in MB/s for simple        */
/* computational kernels coded in C.                                     */
/*-----------------------------------------------------------------------*/
/* Copyright 1991-2013: John D. McCalpin                                 */
/*-----------------------------------------------------------------------*/
/* License:                                                              */
/*  1. You are free to use this program and/or to redistribute           */
/*     this program.                                                     */
/*  2. You are free to modify this program for your own use,             */
/*     including commercial use, subject to the publication              */
/*     restrictions in item 3.                                           */
/*  3. You are free to publish results obtained from running this        */
/*     program, or from works that you derive from this program,         */
/*     with the following limitations:                                   */
/*     3a. In order to be referred to as "STREAM benchmark results",     */
/*         published results must be in conformance to the STREAM        */
/*         Run Rules, (briefly reviewed below) published at              */
/*         http://www.cs.virginia.edu/stream/ref.html                    */
/*         and incorporated herein by reference.                         */
/*         As the copyright holder, John McCalpin retains the            */
/*         right to determine conformity with the Run Rules.             */
/*     3b. Results based on modified source code or on runs not in       */
/*         accordance with the STREAM Run Rules must be clearly          */
/*         labelled whenever they are published.  Examples of            */
/*         proper labelling include:                                     */
/*           "tuned STREAM benchmark results"                            */
/*           "based on a variant of the STREAM benchmark code"           */
/*         Other comparable, clear, and reasonable labelling is          */
/*         acceptable.                                                   */
/*     3c. Submission of results to the STREAM benchmark web site        */
/*         is encouraged, but not required.                              */
/*  4. Use of this program or creation of derived works based on this    */
/*     program constitutes acceptance of these licensing restrictions.   */
/*  5. Absolutely no warranty is expressed or implied.                   */
/*-----------------------------------------------------------------------*/
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <float.h>
#include <getopt.h>
#include <limits.h>
#include <math.h>
#include <numa.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>
#include <stdbool.h>

/*-----------------------------------------------------------------------
 * INSTRUCTIONS:
 *
 *	1) STREAM requires different amounts of memory to run on different
 *           systems, depending on both the system cache size(s) and the
 *           granularity of the system timer.
 *     You should adjust the value of 'STREAM_ARRAY_SIZE' (below)
 *           to meet *both* of the following criteria:
 *       (a) Each array must be at least 4 times the size of the
 *           available cache memory. I don't worry about the difference
 *           between 10^6 and 2^20, so in practice the minimum array size
 *           is about 3.8 times the cache size.
 *           Example 1: One Xeon E3 with 8 MB L3 cache
 *               STREAM_ARRAY_SIZE should be >= 4 million, giving
 *               an array size of 30.5 MB and a total memory requirement
 *               of 91.5 MB.
 *           Example 2: Two Xeon E5's with 20 MB L3 cache each (using OpenMP)
 *               STREAM_ARRAY_SIZE should be >= 20 million, giving
 *               an array size of 153 MB and a total memory requirement
 *               of 458 MB.
 *       (b) The size should be large enough so that the 'timing calibration'
 *           output by the program is at least 20 clock-ticks.
 *           Example: most versions of Windows have a 10 millisecond timer
 *               granularity.  20 "ticks" at 10 ms/tic is 200 milliseconds.
 *               If the chip is capable of 10 GB/s, it moves 2 GB in 200 msec.
 *               This means the each array must be at least 1 GB, or 128M elements.
 *
 *      Version 5.10 increases the default array size from 2 million
 *          elements to 10 million elements in response to the increasing
 *          size of L3 caches.  The new default size is large enough for caches
 *          up to 20 MB.
 *      Version 5.10 changes the loop index variables from "register int"
 *          to "ssize_t", which allows array indices >2^32 (4 billion)
 *          on properly configured 64-bit systems.  Additional compiler options
 *          (such as "-mcmodel=medium") may be required for large memory runs.
 */
static uint64_t stream_array_size = 1000000;

/*  2) STREAM runs each kernel "NTIMES" times and reports the *best* result
 *         for any iteration after the first, therefore the minimum value
 *         for NTIMES is 2.
 *      There are no rules on maximum allowable values for NTIMES, but
 *         values larger than the default are unlikely to noticeably
 *         increase the reported performance.
 */
static uint16_t ntimes = 10;

/*  Users are allowed to modify the "OFFSET" variable, which *may* change the
 *         relative alignment of the arrays (though compilers may change the
 *         effective offset by making the arrays non-contiguous on some systems).
 *      Use of non-zero values for OFFSET can be especially helpful if the
 *         STREAM_ARRAY_SIZE is set to a value close to a large power of 2.
 */
static uint16_t offset = 0;

/*
 *	3) Compile the code with optimization.  Many compilers generate
 *       unreasonably bad code before the optimizer tightens things up.
 *     If the results are unreasonably good, on the other hand, the
 *       optimizer might be too smart for me!
 *
 *     For a simple single-core version, try compiling with:
 *            cc -O stream.c -o stream
 *     This is known to work on many, many systems....
 *
 *     To use multiple cores, you need to tell the compiler to obey the OpenMP
 *       directives in the code.  This varies by compiler, but a common example is
 *            gcc -O -fopenmp stream.c -o stream_omp
 *       The environment variable OMP_NUM_THREADS allows runtime control of the
 *         number of threads/cores used when the resulting "stream_omp" program
 *         is executed.
 *
 *     To run with single-precision variables and arithmetic, simply add
 *         -DSTREAM_TYPE=float
 *     to the compile line.
 *     Note that this changes the minimum array sizes required --- see (1) above.
 *
 *     The preprocessor directive "TUNED" does not do much -- it simply causes the
 *       code to call separate functions to execute each kernel.  Trivial versions
 *       of these functions are provided, but they are *not* tuned -- they just
 *       provide predefined interfaces to be replaced with tuned code.
 *
 *
 *	4) Optional: Mail the results to mccalpin@cs.virginia.edu
 *	   Be sure to include info that will help me understand:
 *		a) the computer hardware configuration (e.g., processor model,
 *          memory type)
 *      b) the compiler name/version and compilation flags c) any run-time information
 *          (such as OMP_NUM_THREADS) d) all of the output from the test case.
 *
 * Thanks!
 *
 *-----------------------------------------------------------------------*/

#define HLINE "-------------------------------------------------------------\n"

#ifndef MIN
#define MIN(x, y) ((x) < (y) ? (x) : (y))
#endif
#ifndef MAX
#define MAX(x, y) ((x) > (y) ? (x) : (y))
#endif

#ifndef STREAM_TYPE
#define STREAM_TYPE double
#endif

static STREAM_TYPE *a1, *a2, *b1, *b2, *c1, *c2;

static double avgtime[8] = {0}, maxtime[8] = {0},
              mintime[8] = {FLT_MAX, FLT_MAX, FLT_MAX, FLT_MAX,
                            FLT_MAX, FLT_MAX, FLT_MAX, FLT_MAX};

static char *label[4] = {"Copy:      ", "Scale:     ", "Add:       ", "Triad:     "};

static const STREAM_TYPE A_TUNED = 1.0, B_TUNED = 2.0, C_TUNED = 0.0;

static const int TIMES_LEN = 8;
static bool use_malloc = false;

extern double mysecond();
#ifdef TUNED
extern void tuned_STREAM_Copy(STREAM_TYPE *, STREAM_TYPE *);
extern void tuned_STREAM_Scale(STREAM_TYPE, STREAM_TYPE *, STREAM_TYPE *);
extern void tuned_STREAM_Add(STREAM_TYPE *, STREAM_TYPE *, STREAM_TYPE *);
extern void tuned_STREAM_Triad(STREAM_TYPE, STREAM_TYPE *, STREAM_TYPE *, STREAM_TYPE *);
#endif
#ifdef _OPENMP
extern int omp_get_num_threads();
#endif

static struct option long_options[8] = {
    {"ntimes", required_argument, 0, 't'},
    {"array-size", required_argument, 0, 'a'},
    {"offset", required_argument, 0, 'o'},
    {"numa-nodes", required_argument, 0, 'n'},
    {"auto-array-size", no_argument, 0, 's'},
    {"help", no_argument, 0, 'h'},
    {"malloc", no_argument, 0, 'm'},
    {0, 0, 0, 0}
};

static void parse_numa_from_cli(uint64_t *numa_nodes, char *arg) {
    if (strchr(arg, ',') == NULL) {
        numa_nodes[0] = numa_nodes[1] = atoll(arg);
    } else {
        char *s1 = strdup(arg);
        char *s0 = strsep(&s1, ",");

        numa_nodes[0] = atoll(s0);
        numa_nodes[1] = atoll(s1);

        free(s0);
    }
}

static const int HELP_LEN = 7;
static char *HELP[] = {
    "     --ntimes, -t <integer-value>                             : Number of times to "
    "run benchmark: Default 10",
    "     --array-size, -a <integer-value>|<integer-value><K|M|G>  : Size of numa node "
    "arrays: Default 1000000",
    "     --offset, -o <integer-value>                             : Change relative "
    "alignment of arrays: Default 0",
    "     --numa-nodes, -n <integer>,<integer>|<integer>           : Numa "
    "node(s) to allocate the arrays using numa_alloc_onnode",
    "     --auto-array-size, -s                                    : Array will be "
    "socket's L3 cache divided by 2",
    "     --malloc, -m                                             : Use normal malloc to allocate "
    "the arrays",
    "     --help, -h                                               : Print this message"
};

static void output_help() {
    printf("STREAM Benchmark\n");
    for (int i = 0; i < HELP_LEN; i++) {
        printf("%s\n", HELP[i]);
    }

    exit(EXIT_SUCCESS);
}

static uint64_t calculate_array_size() {
    // `_SC_LEVEL3_CACHE_SIZE` is used instead of sysfs's `size` for more precision.
    uint64_t size = sysconf(_SC_LEVEL3_CACHE_SIZE) / 2;

    return size;
}

static uint64_t convert_array_size(char *s) {
    char last_char = s[strlen(s) - 1];

    if (isdigit(last_char)) {
        return atoll(s);
    }

    uint64_t last_digit_index = strlen(s) - 1;
    char *s0 = strndup(s, last_digit_index);

    uint64_t base = atoll(s0);

    switch (last_char) {
    case 'K':
        base *= 1000;
        break;
    case 'M':
        base *= 1e6; // 1 million
        break;
    case 'G':
        base *= 1e9; // 1 billion
        break;
    default:
        break;
    }

    free(s0);

    return base;
}

static uint64_t *parse_cli_args(int argc, char **argv, uint64_t *numa_nodes) {
    int c;
    bool found_numa = false;

    if (argc == 1) {
        output_help();
        exit(1);
    }

    while (1) {
        int option_index = 0;

        c = getopt_long(argc, argv, "t:a:o:n:s:hm", long_options, &option_index);
        if (c == -1) {
            break;
        }

        if (long_options[option_index].flag != 0) {
            break;
        }

        switch (c) {
        case 't':
            if (optarg) {
                ntimes = atoi(optarg);
            }
            else {
                printf("-t requires a value");
                output_help();
                exit(1);
            }
            break;
        case 'a':
            if (optarg) {
                stream_array_size = convert_array_size(optarg);
            }
            else {
                printf("-a requires a value");
                output_help();
                exit(1);
            }
            break;
        case 'o':
            if (optarg) {
                offset = atoi(optarg);
            }
            else {
                printf("-0 requires a value");
                output_help();
                exit(1);
            }
            break;
        case 'n':
            if (optarg) {
                parse_numa_from_cli(numa_nodes, optarg);
                found_numa = true;
            } else {
                printf("-n requires a value");
                output_help();
                exit(1);
            }
            break;
        case 's':
            stream_array_size = calculate_array_size();
            break;
        case 'h':
            output_help();
            break;
        case 'm':
            use_malloc = true;
            break;
        default:
            printf("unrecognized option\n");
            output_help();
            exit(1);
            break;
        }
    }

    if (!found_numa && !use_malloc) {
        printf("No numa nodes inputted. Aborting.\n");
        output_help();
        exit(1);
    }

    if (found_numa && use_malloc) {
        printf("Only one of --malloc or --numa-nodes is permitted.\n");
        output_help();
        exit(1);
    }

    if (use_malloc) {
        numa_nodes[0] = numa_nodes[1] = 0;
    }

    return numa_nodes;
}

#define M 20

static int checktick(void) {
    int i, minDelta, Delta;
    double t1, t2, timesfound[M];

    /*  Collect a sequence of M unique time values from the system. */

    for (i = 0; i < M; i++) {
        t1 = mysecond();
        while (((t2 = mysecond()) - t1) < 1.0E-6)
            ;
        timesfound[i] = t1 = t2;
    }

    /*
     * Determine the minimum difference between these M values.
     * This result will be our estimate (in microseconds) for the
     * clock granularity.
     */

    minDelta = 1000000;
    for (i = 1; i < M; i++) {
        Delta = (int)(1.0E6 * (timesfound[i] - timesfound[i - 1]));
        minDelta = MIN(minDelta, MAX(Delta, 0));
    }

    return (minDelta);
}

/* A gettimeofday routine to give access to the wall
   clock timer on most UNIX-like systems.  */

#include <sys/time.h>

double mysecond() {
    struct timeval tp;
    struct timezone tzp;

    gettimeofday(&tp, &tzp);
    return ((double)tp.tv_sec + (double)tp.tv_usec * 1.e-6);
}

static void upperbound_errors(uint64_t *err, uint64_t *ierr, double epsilon, STREAM_TYPE *x,
                              STREAM_TYPE xj, STREAM_TYPE x_avg_err, char *x_array_name) {
    if (llabs(x_avg_err / xj) > epsilon) {
        (*err)++;
        printf("Failed Validation on array %s, AvgRelAbsErr > epsilon (%e)\n",
               x_array_name, epsilon);
        printf("     Expected Value: %e, AvgAbsErr: %e, AvgRelAbsErr: %e\n", xj,
               x_avg_err, abs(x_avg_err) / xj);
        *ierr = 0;
        for (ssize_t j = 0; j < stream_array_size; j++) {
            if (abs(x[j] / xj - 1.0) > epsilon) {
                (*ierr)++;
#ifdef VERBOSE
                if (ierr < 10) {
                    printf("         array %s: index: %ld, expected: %e, observed: %e, "
                           "relative error: %e\n",
                           x_array_name, j, xj, x[j], abs((xj - x[j]) / x_avg_err));
                }
#endif
            }
        }
        printf("     For array %s[], %ld errors were found.\n", x_array_name, *ierr);
    }
}

#ifndef abs
#define abs(a) ((a) >= 0 ? (a) : -(a))
#endif
static void checkSTREAMresults() {
    STREAM_TYPE a1j, a2j, b1j, b2j, c1j, c2j, scalar;
    STREAM_TYPE a1SumErr, a2SumErr, b1SumErr, b2SumErr, c1SumErr, c2SumErr;
    STREAM_TYPE a1AvgErr, a2AvgErr, b1AvgErr, b2AvgErr, c1AvgErr, c2AvgErr;
    double epsilon;
    ssize_t j;
    int k;

    /* reproduce initialization */
    a1j = a2j = A_TUNED;
    b1j = b2j = B_TUNED;
    c1j = c2j = C_TUNED;

    /* a1[] is modified during timing check */
    a1j = 2.0E0 * a1j;
    a2j = 2.0E0 * a2j;
    /* now execute timing loop */
    scalar = 3.0;
    for (k = 0; k < ntimes; k++) {
        // i. copy node1-to-node2. (read a1, write b2)
        b2j = a1j;
        // ii. scale node2-to-node1 (read b2, write a1)
        a1j = scalar * b2j;
        // iii. add node1-to-node2 (read a1, b1, write c2)
        c2j = a1j + b1j;
        // iv. triad node2-to-node1 (read b2, c2, write a1)
        a1j = b2j + scalar * c2j;
        // v. copy node2-to-node1 (read a2, write b1)
        b1j = a2j;
        // vi. scale node1-to-node2 (read b1, write a2)
        a2j = scalar * b1j;
        // vii. add node2-to-node1 (read a2, b2, write c1)
        c1j = a2j + b2j;
        // viii. triad node1-to-node2 (read b1, c1, write a2)
        a2j = b1j + scalar * c1j;
    }

    /* accumulate deltas between observed and expected results */
    a1SumErr = 0.0;
    a2SumErr = 0.0;

    b1SumErr = 0.0;
    b2SumErr = 0.0;

    c1SumErr = 0.0;
    c2SumErr = 0.0;
    for (j = 0; j < stream_array_size; j++) {
        a1SumErr += abs(a1[j] - a1j);
        a2SumErr += abs(a2[j] - a2j);

        b1SumErr += abs(b1[j] - b1j);
        b2SumErr += abs(b2[j] - b2j);

        c1SumErr += abs(c1[j] - c1j);
        c2SumErr += abs(c2[j] - c2j);
        // if (j == 417) printf("Index 417: c[j]: %f, cj: %f\n",c[j],cj);	//
        // MCCALPIN
    }
    a1AvgErr = a1SumErr / (STREAM_TYPE)stream_array_size;
    a2AvgErr = a2SumErr / (STREAM_TYPE)stream_array_size;

    b1AvgErr = b1SumErr / (STREAM_TYPE)stream_array_size;
    b2AvgErr = b2SumErr / (STREAM_TYPE)stream_array_size;

    c1AvgErr = c1SumErr / (STREAM_TYPE)stream_array_size;
    c2AvgErr = c2SumErr / (STREAM_TYPE)stream_array_size;

    if (sizeof(STREAM_TYPE) == 4) {
        epsilon = 1.e-6;
    } else if (sizeof(STREAM_TYPE) == 8) {
        epsilon = 1.e-13;
    } else {
        printf("WEIRD: sizeof(STREAM_TYPE) = %lu\n", sizeof(STREAM_TYPE));
        epsilon = 1.e-6;
    }

    uint64_t err = 0;
    uint64_t ierr = 0;
    upperbound_errors(&err, &ierr, epsilon, a1, a1j, a1AvgErr, "a1");
    upperbound_errors(&err, &ierr, epsilon, a2, a2j, a2AvgErr, "a2");

    upperbound_errors(&err, &ierr, epsilon, b1, b1j, b1AvgErr, "b1");
    upperbound_errors(&err, &ierr, epsilon, b2, b2j, b2AvgErr, "b2");

    upperbound_errors(&err, &ierr, epsilon, c1, c1j, c1AvgErr, "c1");
    upperbound_errors(&err, &ierr, epsilon, c2, c2j, c2AvgErr, "c2");

    if (err == 0) {
        printf("Solution Validates: avg error less than %e on all three arrays\n",
               epsilon);
    }

#ifdef VERBOSE
    printf("Results Validation Verbose Results: \n");
    printf("    Expected a1(1), a2(1), b1(1), b2(1), c1(1), c2(1): %f %f %f %f %f %f \n",
           a1j, a2j, b1j, b2j, c1j, c2j);
    printf("    Observed a1(1), a2(1), b1(1), b2(1), c1(1), c2(1): %f %f %f %f %f %f \n",
           a1[1], a2[1], b1[1], b2[1], c1[1], c2[1]);
    printf("    Rel Errors on a1, a2, b1, b2, c1, c2:     %e %e %e \n",
           abs(a1AvgErr / a1j), abs(a2AvgErr / a2j), abs(b1AvgErr / b1j),
           abs(b2AvgErr / b2j), abs(c1AvgErr / c1j), abs(c2AvgErr / c2j));
#endif
}

#ifdef TUNED
/* stubs for "tuned" versions of the kernels */
void tuned_STREAM_Copy(STREAM_TYPE *x, STREAM_TYPE *y) {
    ssize_t j;
#pragma omp parallel for
    for (j = 0; j < stream_array_size; j++)
        x[j] = y[j];
}

void tuned_STREAM_Scale(STREAM_TYPE scalar, STREAM_TYPE *x, STREAM_TYPE *y) {
    ssize_t j;
#pragma omp parallel for
    for (j = 0; j < stream_array_size; j++)
        x[j] = scalar * y[j];
}

void tuned_STREAM_Add(STREAM_TYPE *x, STREAM_TYPE *y, STREAM_TYPE *z) {
    ssize_t j;
#pragma omp parallel for
    for (j = 0; j < stream_array_size; j++)
        x[j] = y[j] + z[j];
}

void tuned_STREAM_Triad(STREAM_TYPE scalar, STREAM_TYPE *x, STREAM_TYPE *y,
                        STREAM_TYPE *z) {
    ssize_t j;

#pragma omp parallel for
    for (j = 0; j < stream_array_size; j++)
        x[j] = y[j] + scalar * z[j];
}
/* end of stubs for the "tuned" versions of the kernels */
#endif

int main(int argc, char **argv) {
    size_t numa_nodes[2] = {-1, -1};

    parse_cli_args(argc, argv, numa_nodes);

    int quantum; // , checktick();
    int BytesPerWord;
    int k;
    ssize_t j;
    STREAM_TYPE scalar;
    double t, times[8][ntimes];

    double bytes[8] = {2 * sizeof(STREAM_TYPE) * stream_array_size,
                       2 * sizeof(STREAM_TYPE) * stream_array_size,
                       3 * sizeof(STREAM_TYPE) * stream_array_size,
                       3 * sizeof(STREAM_TYPE) * stream_array_size,
                       2 * sizeof(STREAM_TYPE) * stream_array_size,
                       2 * sizeof(STREAM_TYPE) * stream_array_size,
                       3 * sizeof(STREAM_TYPE) * stream_array_size,
                       3 * sizeof(STREAM_TYPE) * stream_array_size};

    int from_node = numa_nodes[0];
    int to_node = numa_nodes[1];

    uint64_t numa_node_size = (stream_array_size + offset) * sizeof(STREAM_TYPE);

    numa_set_strict(1);

    if (use_malloc) {
        a1 = (STREAM_TYPE *)malloc(numa_node_size);
        a2 = (STREAM_TYPE *)malloc(numa_node_size);

        b1 = (STREAM_TYPE *)malloc(numa_node_size);
        b2 = (STREAM_TYPE *)malloc(numa_node_size);

        c1 = (STREAM_TYPE *)malloc(numa_node_size);
        c2 = (STREAM_TYPE *)malloc(numa_node_size);
    } else {
        a1 = (STREAM_TYPE *)numa_alloc_onnode(numa_node_size, from_node);
        a2 = (STREAM_TYPE *)numa_alloc_onnode(numa_node_size, to_node);

        b1 = (STREAM_TYPE *)numa_alloc_onnode(numa_node_size, from_node);
        b2 = (STREAM_TYPE *)numa_alloc_onnode(numa_node_size, to_node);

        c1 = (STREAM_TYPE *)numa_alloc_onnode(numa_node_size, from_node);
        c2 = (STREAM_TYPE *)numa_alloc_onnode(numa_node_size, to_node);
    }

    if (!a1 || !a2 || !b1 || !b2 || !c1 || !c2) {
        printf("ERROR: failed to allocate memory.  Reduce the array sizes and retry"
               "Aborting.\n");
        output_help();
        exit(1);
    }

    /* --- SETUP --- determine precision and check timing --- */

    printf(HLINE);
    printf("STREAM version $Revision: 5.10 $\n");
    printf(HLINE);
    BytesPerWord = sizeof(STREAM_TYPE);
    printf("This system uses %d bytes per array element.\n", BytesPerWord);

    printf(HLINE);
#ifdef N
    printf("*****  WARNING: ******\n");
    printf("      It appears that you set the preprocessor variable N when compiling "
           "this code.\n");
    printf("      This version of the code uses the preprocesor variable "
           "STREAM_ARRAY_SIZE to control the array size\n");
    printf("      Reverting to default value of STREAM_ARRAY_SIZE=%llu\n",
           (unsigned long long)STREAM_ARRAY_SIZE);
    printf("*****  WARNING: ******\n");
#endif

    printf("Array size = %llu (elements), Offset = %d (elements)\n",
           (unsigned long long)stream_array_size, offset);
    printf("Memory per array = %.1f MiB (= %.1f GiB).\n",
           BytesPerWord * ((double)stream_array_size / 1024.0 / 1024.0),
           BytesPerWord * ((double)stream_array_size / 1024.0 / 1024.0 / 1024.0));
    printf("Total memory required = %.1f MiB (= %.1f GiB).\n",
           (6.0 * BytesPerWord) * ((double)stream_array_size / 1024.0 / 1024.),
           (6.0 * BytesPerWord) * ((double)stream_array_size / 1024.0 / 1024. / 1024.));
    printf("Each kernel will be executed %d times.\n", ntimes);
    printf(" The *best* time for each kernel (excluding the first iteration)\n");
    printf(" will be used to compute the reported bandwidth.\n");

#ifdef _OPENMP
    printf(HLINE);
#pragma omp parallel
    {
#pragma omp master
        {
            k = omp_get_num_threads();
            printf("Number of Threads requested = %i\n", k);
        }
    }
#endif

#ifdef _OPENMP
    k = 0;
#pragma omp parallel
#pragma omp atomic
    k++;
    printf("Number of Threads counted = %i\n", k);
#endif

    /* Get initial value for system clock. */
#pragma omp parallel for
    for (j = 0; j < stream_array_size; j++) {
        a1[j] = a2[j] = A_TUNED;
        b1[j] = b2[j] = B_TUNED;
        c1[j] = c2[j] = C_TUNED;
    }

    printf(HLINE);

    if ((quantum = checktick()) >= 1)
        printf("Your clock granularity/precision appears to be "
               "%d microseconds.\n",
               quantum);
    else {
        printf("Your clock granularity appears to be "
               "less than one microsecond.\n");
        quantum = 1;
    }

    t = mysecond();
#pragma omp parallel for
    for (j = 0; j < stream_array_size; j++)
        a1[j] = 2.0E0 * a1[j];
    t = 1.0E6 * (mysecond() - t);

    printf("Each test below will take on the order"
           " of %d microseconds.\n",
           (int)t);
    printf("   (= %d clock ticks)\n", (int)(t / quantum));
    printf("Increase the size of the arrays if this shows that\n");
    printf("you are not getting at least 20 clock ticks per test.\n");

    printf(HLINE);

    printf("WARNING -- The above is only a rough guideline.\n");
    printf("For best results, please be sure you know the\n");
    printf("precision of your system timer.\n");
    printf(HLINE);

    /*	--- MAIN LOOP --- repeat test cases ntimes times --- */

    scalar = 3.0;
    for (k = 0; k < ntimes; k++) {
        times[0][k] = mysecond();
#ifdef TUNED
        tuned_STREAM_Copy(b2, a1);
#else
#pragma omp parallel for
        // i. copy node1-to-node2. (read a1, write b2)
        for (j = 0; j < stream_array_size; j++)
            b2[j] = a1[j];
#endif
        times[0][k] = mysecond() - times[0][k];

        times[5][k] = mysecond();
#ifdef TUNED
        tuned_STREAM_Scale(scalar, a1, b2);
#else
#pragma omp parallel for
        // ii. scale node2-to-node1 (read b2, write a1)
        for (j = 0; j < stream_array_size; j++)
            a1[j] = scalar * b2[j];
#endif
        times[5][k] = mysecond() - times[5][k];

        times[2][k] = mysecond();
#ifdef TUNED
        tuned_STREAM_Add(c2, a1, b1);
#else
#pragma omp parallel for
        // iii. add node1-to-node2 (read a1, b1, write c2)
        for (j = 0; j < stream_array_size; j++)
            c2[j] = a1[j] + b1[j];
#endif
        times[2][k] = mysecond() - times[2][k];

        times[7][k] = mysecond();
#ifdef TUNED
        tuned_STREAM_Triad(scalar, a2, b2, c2);
#else
#pragma omp parallel for
        // iv. triad node2-to-node1 (read b2, c2, write a1)
        for (j = 0; j < stream_array_size; j++)
            a1[j] = b2[j] + scalar * c2[j];
#endif
        times[7][k] = mysecond() - times[7][k];

        times[4][k] = mysecond();
#ifdef TUNED
        tuned_STREAM_Copy(b1, a2);
#else
#pragma omp parallel for
        // v. copy node2-to-node1 (read a2, write b1)
        for (j = 0; j < stream_array_size; j++)
            b1[j] = a2[j];
#endif
        times[4][k] = mysecond() - times[4][k];

        times[1][k] = mysecond();
#ifdef TUNED
        tuned_STREAM_Scale(scalar, a2, b1);
#else
#pragma omp parallel for
        // vi. scale node1-to-node2 (read b1, write a2)
        for (j = 0; j < stream_array_size; j++)
            a2[j] = scalar * b1[j];
#endif
        times[1][k] = mysecond() - times[1][k];

        times[6][k] = mysecond();
#ifdef TUNED
        tuned_STREAM_Add(c1, a2, b2);
#else
#pragma omp parallel for
        // vii. add node2-to-node1 (read a2, b2, write c1)
        for (j = 0; j < stream_array_size; j++)
            c1[j] = a2[j] + b2[j];
#endif
        times[6][k] = mysecond() - times[6][k];

        times[3][k] = mysecond();
#ifdef TUNED
        tuned_STREAM_Triad(scalar, a2, b1, c1);
#else
#pragma omp parallel for
        // viii. triad node1-to-node2 (read b1, c1, write a2)
        for (j = 0; j < stream_array_size; j++)
            a2[j] = b1[j] + scalar * c1[j];
#endif
        times[3][k] = mysecond() - times[3][k];
    }

    /*	--- SUMMARY --- */

    for (k = 1; k < ntimes; k++) /* note -- skip first iteration */
    {
        for (j = 0; j < TIMES_LEN; j++) {
            avgtime[j] = avgtime[j] + times[j][k];
            mintime[j] = MIN(mintime[j], times[j][k]);
            maxtime[j] = MAX(maxtime[j], times[j][k]);
        }
    }

    int REPORT_LEN = TIMES_LEN;
    if (numa_nodes[0] == numa_nodes[1]) {
        /* A single NUMA node is tested, make sure that the
         * report considers this fact to consolidate the best
         */
        REPORT_LEN = TIMES_LEN / 2;
        for (k = 1; k < REPORT_LEN; k++) {
            mintime[k] = MIN(mintime[k], mintime[k + REPORT_LEN]);
            maxtime[k] = MAX(maxtime[k], maxtime[k + REPORT_LEN]);
        }
    }

    printf(
        "Function     Direction    BestRateMBs     AvgTime      MinTime      MaxTime\n");
    for (j = 0; j < REPORT_LEN; j++) {
        avgtime[j] = avgtime[j] / (double)(ntimes - 1);

        if (j < (TIMES_LEN / 2)) {
            printf("%s  %ld->%ld  %18.1f  %11.6f  %11.6f  %11.6f\n", label[j % 4],
                   numa_nodes[0], numa_nodes[1], 1.0E-06 * bytes[j] / mintime[j],
                   avgtime[j], mintime[j], maxtime[j]);
        } else {
            printf("%s  %ld->%ld  %18.1f  %11.6f  %11.6f  %11.6f\n", label[j % 4],
                   numa_nodes[1], numa_nodes[0], 1.0E-06 * bytes[j] / mintime[j],
                   avgtime[j], mintime[j], maxtime[j]);
        }
    }
    printf(HLINE);

    /* --- Check Results --- */
    checkSTREAMresults();
    printf(HLINE);

    /* --- Cleaning Up --- */

    if (use_malloc) {
        free(a1);
        free(a2);

        free(b1);
        free(b2);

        free(c1);
        free(c2);
    } else {
        numa_free(a1, numa_node_size);
        numa_free(a2, numa_node_size);

        numa_free(b1, numa_node_size);
        numa_free(b2, numa_node_size);

        numa_free(c1, numa_node_size);
        numa_free(c2, numa_node_size);
    }

    return 0;
}
