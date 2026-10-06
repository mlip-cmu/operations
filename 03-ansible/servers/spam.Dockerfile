# A spam filter server: the image from 01, run by a service manager (supervisor),
# with its configuration in /etc/spamfilter/spamfilter.env
FROM spamfilter:1.0
USER root
RUN apt-get update && apt-get install -y --no-install-recommends supervisor && rm -rf /var/lib/apt/lists/*
COPY spamfilter.supervisor.conf /etc/supervisor/conf.d/spamfilter.conf
HEALTHCHECK NONE
CMD ["supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
