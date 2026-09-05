# The frontend is a separate image from the API, deployed and scaled
# independently. That separation is deliberate: it means a bad frontend push
# cannot take the API down, the two can be rolled back independently, and the
# ALB routing between them becomes a real thing that can be misconfigured.
#
# nginx-unprivileged rather than the standard nginx image: the official one
# starts as root and drops privileges via its entrypoint, which the
# `restricted` Pod Security Standard on this namespace forbids.
FROM nginxinc/nginx-unprivileged:1.29-alpine

# uid 101 (nginx) is already the default USER in this image.

COPY --chown=101:101 nginx.conf /etc/nginx/nginx.conf
COPY --chown=101:101 index.html /usr/share/nginx/html/index.html

# The scratch directories nginx.conf points at. Created here so the container
# works with readOnlyRootFilesystem plus an emptyDir mounted at /tmp.
USER 0
RUN mkdir -p /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp \
             /tmp/uwsgi_temp /tmp/scgi_temp \
 && chown -R 101:101 /tmp
USER 101

EXPOSE 8080

# Fail the build rather than the deploy if the config is invalid.
RUN nginx -t -c /etc/nginx/nginx.conf
