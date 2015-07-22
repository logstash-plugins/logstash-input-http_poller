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

echo Pulling tutum/hapoxy | tee -a $BUILDLOG
docker pull tutum/haproxy

echo "Starting $NUM_APACHES Apaches" | tee -a $BUILDLOG

links=""
apache_ls_config_urls=""
for i in `seq 1 $NUM_APACHES`;
do
  name=custom_httpd_t$i
  links="$links --link $name:$name"
  port=$((8000+$i))
  url="http://$MACHINE_IP:$port"
  status_url="$url/server-status"
  apache_ls_config_urls="$apache_ls_config_urls
      \"$name\" => \"$status_url\""
  echo Starting $name on $url | tee -a $BUILDLOG
  echo Status for $name on $satus_url | tee -a $BUILDLOG
  docker stop $name >> $BUILDLOG
  docker rm $name >> $BUILDLOG
  docker run -d -p $port:80 --name $name custom_httpd 2>&1 >> $BUILDLOG
done

ha_proxy_url="http://$MACHINE_IP:80"
ha_proxy_stats_url="http://$HAPROXY_STATS_USER:$HAPROXY_STATS_PASS@$MACHINE_IP:$HAPROXY_STATS_PORT"
echo "Starting haproxy on $ha_proxy_url" | tee -a $BUILDLOG
echo "haproxy stats will be available on $ha_proxy_stats_url"

docker stop custom_haproxy >> $BUILDLOG
docker rm custom_haproxy >> $BUILDLOG
docker run -d -p 80:80 -p $HAPROXY_STATS_PORT:$HAPROXY_STATS_PORT -e STATS_PORT=$HAPROXY_STATS_PORT -e STATS_AUTH=$HAPROXY_STATS_USER:$HAPROXY_STATS_PASS --name custom_haproxy $links tutum/haproxy

echo "Logstash Config: "

cat <<EOCONFIG > logstash.conf
input {
  http_poller {
    urls => {
      $apache_ls_config_urls
     }
     tags => apache_stats
     codec => plain
     target => apache_stats
     metadata_target => _http_poller_metadata
     interval => 10
  }

  http_poller {
    urls => {
      ha_proxy_stats => {
        url => "http://$MACHINE_IP:$HAPROXY_STATS_PORT"
        auth => {
          user => "$HAPROXY_STATS_USER"
          password => "$HAPROXY_STATS_PASS"
        }
      }
    }
    tags => haproxy_stats
    codec => plain
    target => haproxy_stats
    metadata_target => _http_poller_metadata
    interval => 10
   }

   # Listen to raw output from all servers
   #syslog {}
}

filter {
  if "apache_stats" in [tags] {
    kv {
      source => apache_stats
      target => apache_stats
      field_split => "\n"
      value_split => ": "
      trim => " "
    }
  }

  if "haproxy_stats" in [tags] {
    split {}

    # We can't read the haproxy csv header, so we define it statically
    csv {
       columns => [ pxname,svname,qcur,qmax,scur,smax,slim,stot,bin,bout,dreq,dresp,ereq,econ,eresp,wretr,wredis,status,weight,act,bck,chkfail,chkdown,lastchg,downtime,qlimit,pid,iid,sid,throttle,lbtot,tracked,type,rate,rate_lim,rate_max,check_status,check_code,check_duration,hrsp_1xx,hrsp_2xx,hrsp_3xx,hrsp_4xx,hrsp_5xx,hrsp_other,hanafail,req_rate,req_rate_max,req_tot,cli_abrt,srv_abrt,comp_in,comp_out,comp_byp,comp_rsp,lastsess,last_chk,last_agt,qtime,ctime,rtime,ttime ]
    }

    # Drop the haproxy CSV header
    if [pxname] == "# pxname" {
      drop{}
    }
  }
}

output {
  stdout {
    codec => rubydebug
  }
}

EOCONFIG
echo Wrote logstash.conf

echo to poll data run: logstash -f logstash.conf

echo "All done!" | tee -a $BUILDLOG

