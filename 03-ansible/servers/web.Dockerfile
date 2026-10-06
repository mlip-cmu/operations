# A web server: nginx, plus Python so that Ansible can manage it
FROM nginx:1.30.5-trixie
RUN apt-get update && apt-get install -y --no-install-recommends python3 && rm -rf /var/lib/apt/lists/*
