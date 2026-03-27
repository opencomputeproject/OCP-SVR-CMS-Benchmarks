##################################################################################################
# OCP SRV CMS - STREAM Benchmark Container
#
# Inherits from ocp-cms-base:latest which provides all common system packages,
# the cms_common.sh library, collect_sysinfo.sh, and generate_report.sh at /opt/cms-utils/.
#
# This layer adds: STREAM source compilation and benchmark scripts.
#
# If the base image is not available, build it first:
#   cd ../utils && docker build -t ocp-cms-base:latest -f Dockerfile.base .
##################################################################################################

FROM ocp-cms-base:latest

# Create working directory
WORKDIR /opt/stream

# Bring over the STREAM source and run scripts
COPY stream/stream.c 			/opt/stream/stream.c
COPY stream/Makefile			/opt/stream/Makefile
COPY stream/run-stream-scaling.sh	/opt/stream/run-stream-scaling.sh
COPY entrypoint.sh			/opt/stream/entrypoint.sh

# Make them executable
RUN chmod +x run-stream-scaling.sh
RUN chmod +x entrypoint.sh

# Build the stream executable
RUN make

# Create results directory
RUN mkdir -p /opt/stream/results

# Default command
ENTRYPOINT ["./entrypoint.sh"]
#CMD
