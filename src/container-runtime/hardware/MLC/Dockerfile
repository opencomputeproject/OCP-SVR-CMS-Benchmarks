##################################################################################################
# OCP SRV CMS - Intel MLC Benchmark Container
#
# Inherits from ocp-cms-base:latest which provides all common system packages,
# the cms_common.sh library, collect_sysinfo.sh, and generate_report.sh at /opt/cms-utils/.
#
# This layer adds: Intel MLC binary download and benchmark scripts.
#
# If the base image is not available, build it first:
#   cd ../utils && docker build -t ocp-cms-base:latest -f Dockerfile.base .
##################################################################################################

FROM ocp-cms-base:latest

# Create working directory
WORKDIR /opt/mlc

# Bring over the setup and run scripts
COPY get_mlc.sh 	/opt/mlc/get_mlc.sh
COPY mlc.sh	 	/opt/mlc/mlc.sh
COPY entrypoint.sh	/opt/mlc/entrypoint.sh

# Make them executable
RUN chmod +x get_mlc.sh
RUN chmod +x mlc.sh
RUN chmod +x entrypoint.sh

# Grab mlc and unpack it then move it to /bin so it's in the path
RUN /opt/mlc/get_mlc.sh
RUN cp /opt/mlc/mlc_v3.11/Linux/mlc /bin/mlc

# Create results directory
RUN mkdir -p /opt/mlc/results

# Default command
ENTRYPOINT ["./entrypoint.sh"]
#CMD
