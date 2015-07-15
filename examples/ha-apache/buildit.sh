#!/bin/bash

BUILDLOG=build.log
MACHINE_IP=`docker-machine ip`
HAPROXY_STATS_PORT=1936
HAPROXY_STATS_USER=statsguy
HAPROXY_STATS_PASS=statspass
NUM_APACHES=3

echo Starting build | tee -a $BUILDLOG

echo Building apache | tee -a $BUILDLOG

cd apache
docker build -t custom_httpd . > $BUILDLOG
cd .. 

echo Installing haproxy | tee -a $BUILDLOG

apache_names+=($name)

echo Pulling tutum/hapoxy:latest | tee -a $BUILDLOG
docker pull tutum/haproxy:latest

echo "Starting $NUM_APACHES Apaches" | tee -a $BUILDLOG

links=""
for i in `seq 1 $NUM_APACHES`;
do
  name=custom_httpd_t$i
  links="$links --link $name:$name"
  port=$((8000+$i))
  echo Starting $name on http://$MACHINE_IP:$port | tee -a $BUILDLOG
  docker stop $name >> $BUILDLOG
  docker rm $name >> $BUILDLOG
  docker run -d -p $port:80 --name $name custom_httpd 2>&1 >> $BUILDLOG
done

echo "Starting haproxy on http://$MACHINE_IP:80" | tee -a $BUILDLOG
echo "haproxy stats will be available on http://$HAPROXY_STATS_USER:$HAPROXY_STATS_PASS@$MACHINE_IP:$HAPROXY_STATS_PORT"

docker stop custom_haproxy >> $BUILDLOG
docker rm custom_haproxy >> $BUILDLOG
docker run -d -p 80:80 -p $HAPROXY_STATS_PORT:$HAPROXY_STATS_PORT -e STATS_PORT=$HAPROXY_STATS_PORT -e STATS_AUTH=$HAPROXY_STATS_USER:$HAPROXY_STATS_PASS --name custom_haproxy $links tutum/haproxy

echo "All done!" | tee -a $BUILDLOG