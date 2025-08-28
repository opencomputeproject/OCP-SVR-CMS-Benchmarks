FROM ubuntu:22.04

# Install necessary packages
RUN apt-get update && apt-get install -y \
    wget \
    tar \
    numactl \
    cxl-cli \
    util-linux \
    python3 \
    python3-pip \
    pciutils \
    bc \
    libnuma-dev \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Create working directory
WORKDIR /opt/stream

#Bring over the STREAM source and run scripts
COPY stream/stream.c 			/opt/stream/stream.c
COPY stream/Makefile			/opt/stream/Makefile
COPY stream/run-stream-scaling.sh	/opt/stream/run-stream-scaling.sh
COPY entrypoint.sh			/opt/stream/entrypoint.sh

#make them executable
RUN chmod +x run-stream-scaling.sh
RUN chmod +x entrypoint.sh

#build the stream executable
RUN make

# Create results directory
RUN mkdir -p /opt/mlc/results

# Default command
ENTRYPOINT ["./entrypoint.sh"]
#CMD
