CC = gcc
CFLAGS = -std=c17 -D_GNU_SOURCE -O3 -mavx2 -mavx512f -fopenmp
DEBUG_CFLAGS = -std=c17 -D_GNU_SOURCE -O0 -mavx2 -mavx512f -g -fsanitize=undefined,address

WARNING_CFLAGS =  -Wall -Wformat-truncation=2 -Werror=return-type -Werror=overflow
WARNING_CFLAGS += -Werror=int-in-bool-context -Werror=parentheses -Wno-unknown-pragmas

CFLAGS += $(WARNING_CFLAGS)
DEBUG_CFLAGS += $(WARNING_CFLAGS)

all: stream_c.exe

stream_c.exe: stream.c
	$(CC) $(CFLAGS) stream.c -lnuma -o stream_c.exe

debug_stream_c.exe: stream.c
	$(CC) $(DEBUG_CFLAGS) stream.c -lnuma -o stream_c.exe

clean:
	rm -f stream_c.exe *.o

# an example of a more complex build line for the Intel icc compiler
stream.icc: stream.c
	icc -O3 -xCORE-AVX2 -ffreestanding -qopenmp stream.c -o stream.omp.AVX2.80M.20x.icc
