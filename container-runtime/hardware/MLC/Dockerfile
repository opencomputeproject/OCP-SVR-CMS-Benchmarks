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
    && rm -rf /var/lib/apt/lists/*

# Create working directory
WORKDIR /opt/mlc

#Bring over the setup and run scripts
COPY get_mlc.sh 	/opt/mlc/get_mlc.sh
COPY mlc.sh	 	/opt/mlc/mlc.sh
COPY entrypoint.sh	/opt/mlc/entrypoint.sh

#make them executable
RUN chmod +x get_mlc.sh
RUN chmod +x mlc.sh
RUN chmod +x entrypoint.sh

#grab mlc and unpack it then move it to /bin so it's in the path
RUN /opt/mlc/get_mlc.sh
RUN cp /opt/mlc/mlc_v3.11/Linux/mlc /bin/mlc

# Create results directory and move to it
RUN mkdir -p /opt/mlc/results

# Default command
ENTRYPOINT ["./entrypoint.sh"]
#CMD
