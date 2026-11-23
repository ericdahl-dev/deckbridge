# getdeckbridge.app (#767): the static site on nginx, with its config in git. Coolify builds this with /website as
# the base directory. Pinned: change the tag on purpose, then run scripts/check_site_image.py.
FROM nginx:1.30.5-alpine
COPY . /usr/share/nginx/html
# The config isn't part of the site: move it into place, and drop this file from what's served.
RUN cd /usr/share/nginx/html \
    && mv nginx.conf /etc/nginx/conf.d/default.conf \
    && rm -f Dockerfile \
    && find . -name .DS_Store -delete
