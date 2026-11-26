# simply-cpp-phpredis

[phpredis](https://github.com/phpredis/phpredis) (the PHP extension for Redis and Valkey, `redis.so`),
built from PECL's release for the Ubuntu release's PHP and packaged as **`php8.5-redis`** in place of
Ubuntu's own package: same files, Ubuntu's maintainer scripts, and a version that sorts above Ubuntu's
(`6.3.0-0sc1~resolute` > `6.2.0-1ubuntu1`) and below a later Ubuntu package of the same release
(`6.3.0-1ubuntu1`). There's no source of ours here beyond the packaging.

Why: Ubuntu resolute ships phpredis 6.2.0, whose `cluster_update_slot()` walks a NULL replica list
after a failover's `MOVED` and kills the php-fpm worker when sessions are kept in a Redis/Valkey
cluster (`session.save_handler = rediscluster`). 6.3.0 has the fix (phpredis PR 2552): it throws
"Redis Cluster's master data is incomplete" instead.

## Install

```bash
curl -fsSL https://apt.roelof.co.za/setup.sh | bash
sudo apt -y install php8.5-redis   # 6.3.0-0sc1~resolute from this repository
php -r 'echo phpversion("redis"), PHP_EOL;'
```

Built as Ubuntu builds it: the php, json and **igbinary** serializers (it depends on `php8.5-igbinary`)
and lz4/zstd compression. Installing or upgrading it enables the module for every SAPI, which fires
php8.5-fpm's dpkg trigger: **dpkg restarts php8.5-fpm**. On a web server stop apache2 first, install,
then start apache2 (one server at a time).

Published for resolute only (build-resolute); noble on demand (`scripts/deploy.sh build-noble`, its PHP
is 8.3, so the package would be php8.3-redis: `php=` in `scripts/publish.sh`).

## The version

`VERSION.txt` is the phpredis release and `SHA256.txt` the checksum of PECL's `redis-<version>.tgz`,
checked against the GitHub tag's sources when it was pinned. The build stops if the tarball ever
changes. `REVISION.txt` is our packaging revision (`0sc1`), kept below Ubuntu's `1ubuntu1` so a later
Ubuntu package of the same release replaces ours. `debian/` holds Ubuntu's maintainer scripts (dh_php's)
unchanged.

## Publishing a new version

Set `VERSION.txt`, `SHA256.txt` (`curl -fsSL https://pecl.php.net/get/redis-<version>.tgz | sha256sum`,
after comparing its sources with the GitHub tag) and `REVISION.txt` (back to `0sc1`), commit, tag
`v<version>-<revision>`, then `scripts/deploy.sh` (or the suite's `scripts/publish.sh resolute --only phpredis`).

## Licence

The packaging scripts are Apache-2.0 (`LICENSE`). phpredis is under the PHP License 3.01; the package's
copyright file carries it.
