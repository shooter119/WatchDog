FROM docker.m.daocloud.io/library/nginx:1.27-alpine
COPY website/ /usr/share/nginx/html/
EXPOSE 80
