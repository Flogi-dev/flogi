# 00_core_infra/03_redis/Dockerfile
FROM redis:7.2.4-alpine 

COPY redis.conf /etc/redis/redis.conf
RUN mkdir -p /data && chown redis:redis /data

EXPOSE 6379
CMD [ "redis-server", "/etc/redis/redis.conf" ]