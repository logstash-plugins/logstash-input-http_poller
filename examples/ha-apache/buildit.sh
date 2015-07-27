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

#echo Pulling tutum/hapoxy | tee -a $BUILDLOG
#docker pull tutum/haproxy

echo "Starting $NUM_APACHES Apaches" | tee -a $BUILDLOG

links=""
apache_ls_config_urls=""
ls_pipe_inputs=""
for i in `seq 1 $NUM_APACHES`;
do
  name=custom_httpd_t$i
  links="$links --link $name:$name"
  port=$((8000+$i))
  url="http://$MACHINE_IP:$port"
  status_url="$url/server-status?auto"
  apache_ls_config_urls="$apache_ls_config_urls
      \"$name\" => { url => \"$status_url\"}"
  echo Starting $name on $url | tee -a $BUILDLOG
  echo Status for $name on $status_url | tee -a $BUILDLOG
  docker stop $name >> $BUILDLOG
  docker rm $name >> $BUILDLOG
  docker run -d -p $port:80 --name $name custom_httpd 2>&1 >> $BUILDLOG
  ls_pipe_inputs="$ls_pipe_inputs
  pipe {
    command => \"docker logs -f $name\"
    tags => [ \"apache\" ]
    add_field => { \"@host\" => \"$name\" }
  }
  "
done

ha_proxy_url="http://$MACHINE_IP:80"
ha_proxy_stats_url="http://$HAPROXY_STATS_USER:$HAPROXY_STATS_PASS@$MACHINE_IP:$HAPROXY_STATS_PORT/;csv"
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
     metadata_target => http_poller_metadata
     interval => 1
  }

  http_poller {
    urls => {
      ha_proxy_stats => {
        url => "$ha_proxy_stats_url"
        auth => {
          user => "$HAPROXY_STATS_USER"
          password => "$HAPROXY_STATS_PASS"
        }
      }
    }
    tags => haproxy_stats
    codec => plain
    metadata_target => http_poller_metadata
    interval => 1
   }

    $ls_pipe_inputs

    pipe {
      command => "docker logs -f custom_haproxy"
      tags => [ "haproxy" ]
      add_field => { "@host" => "custom_haproxy" }
    }
}

filter {
  mutate {
    rename => {
      _http_request_failure => http_request_failure
    }
  }

  if "apache_stats" in [tags] {
    # Make sure all fields are camel cased, no spaces
    mutate {
      gsub => ["message", "^Total ", "Total"]
    }

    kv {
      source => message
      target => apache_stats
      field_split => "\n"
      value_split => ":\ "
      trim => " "
    }

    mutate {
      remove_field => [ "message", "apache_stats[Scoreboard]" ]
      add_field => {
        "@host" => "%{http_poller_metadata[name]}"
      }
    }

    ruby {
      code => "h=event['apache_stats']; h.each {|k,v| h[k] = v.to_f if v =~ /\A-?[0-9\.]+\Z/}"
    }
  }

  if "haproxy_stats" in [tags] {
    split {}

    # We can't read the haproxy csv header, so we define it statically
    csv {
       target => "haproxy_stats"
       columns => [ pxname,svname,qcur,qmax,scur,smax,slim,stot,bin,bout,dreq,dresp,ereq,econ,eresp,wretr,wredis,status,weight,act,bck,chkfail,chkdown,lastchg,downtime,qlimit,pid,iid,sid,throttle,lbtot,tracked,type,rate,rate_lim,rate_max,check_status,check_code,check_duration,hrsp_1xx,hrsp_2xx,hrsp_3xx,hrsp_4xx,hrsp_5xx,hrsp_other,hanafail,req_rate,req_rate_max,req_tot,cli_abrt,srv_abrt,comp_in,comp_out,comp_byp,comp_rsp,lastsess,last_chk,last_agt,qtime,ctime,rtime,ttime ]
    }

    # Drop the haproxy CSV header
    if [haproxy_stats][pxname] == "# pxname" {
      drop{}
    }

    mutate {
      remove_field => message
      add_field => {
        "@host" => "%{[http_poller_metadata][name]}"
      }
    }

    # cast stuff to number
    ruby {
      code => "h=event['haproxy_stats']; h.each {|k,v| h[k] = v.to_f if v =~ /\A-?[0-9\.]+\Z/}"
    }
  }

  if "apache" in [tags] {
    grok {
      match => [ "message", "%{COMMONAPACHELOG:apache}" ]
    }
  }

  if "_http_request_failure" in [tags] {
      metrics {
        meter => [ "_http_request_failure" ]
        add_tag => "_poller_alert"
        flush_interval => 30
      }
  }
}

output {
  #stdout {
  #  codec => rubydebug
  #}

  elasticsearch {
    protocol => http
  }

  if "_poller_alert" in [tags] {
    sns {
      access_key_id => "$AWS_ACCESS_KEY_ID"
      secret_access_key => "$AWS_SECRET_ACCESS_KEY"
      arn => "arn:aws:sns:us-east-1:773216979769:logstash-test-topic"
    }

    stdout {
      codec => rubydebug
    }
  }
}

EOCONFIG
echo Wrote logstash.conf

echo to poll data run: logstash -f logstash.conf

echo "All done!" | tee -a $BUILDLOG
