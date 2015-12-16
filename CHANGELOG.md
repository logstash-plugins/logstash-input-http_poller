## 2.0.1
 - Bump http_client mixin to default to 1 retry for idempotent actions

## 2.0.0
 - Plugins were updated to follow the new shutdown semantic, this mainly allows Logstash to instruct input plugins to terminate gracefully, 
   instead of using Thread.raise on the plugins' threads. Ref: https://github.com/elastic/logstash/pull/3895
 - Dependency on logstash-core update to 2.0

* 1.1.2
  - Correctly default to zero connection retries
  - Revert old ineffective code for connection retries
* 1.1.1
  - Default to zero connection retries
* 1.1.0
  - Error metadata no longer '_' prefixed for kibana compat
  - HTTP metadata now normalized to prevent conflicts with ES schemas
* 1.0.2
  - Bug fix: Decorating the event before pushing it to the queue
* 1.0.1
  - Add 'target' option
* 1.0.0
  - Initial release
