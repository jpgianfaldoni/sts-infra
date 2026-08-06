# Databricks notebook source
# MAGIC %md
# MAGIC # Test RabbitMQ connectivity from serverless compute
# MAGIC
# MAGIC This notebook verifies TCP connectivity through the NCC private endpoint,
# MAGIC publishes a message, consumes it, and deletes the temporary queue.

# COMMAND ----------

# MAGIC %pip install amqp==5.3.1

# COMMAND ----------

import json
import socket
import uuid

from amqp import Connection, Message


dbutils.widgets.text("host", "internal-rabbitmq-nlb.elb.us-west-2.amazonaws.com")
dbutils.widgets.text("port", "5672")
dbutils.widgets.text("secret_scope", "rabbitmq")

host = dbutils.widgets.get("host")
port = int(dbutils.widgets.get("port"))
secret_scope = dbutils.widgets.get("secret_scope")

username = dbutils.secrets.get(scope=secret_scope, key="username")
password = dbutils.secrets.get(scope=secret_scope, key="password")

print(f"Testing RabbitMQ at {host}:{port}")

# COMMAND ----------

resolved_ips = sorted(
    {
        result[4][0]
        for result in socket.getaddrinfo(
            host,
            port,
            family=socket.AF_INET,
            type=socket.SOCK_STREAM,
        )
    }
)
print(f"RabbitMQ hostname resolved to private endpoint IPs: {resolved_ips}")

with socket.create_connection((host, port), timeout=15):
    print("TCP connectivity through the serverless NCC private endpoint succeeded")

# COMMAND ----------

queue_name = f"databricks-serverless-test-{uuid.uuid4().hex}"
message = {
    "source": "databricks-serverless",
    "test_id": uuid.uuid4().hex,
}
body = json.dumps(message).encode("utf-8")

connection = Connection(
    host=f"{host}:{port}",
    userid=username,
    password=password,
    virtual_host="/",
    connect_timeout=15,
)
try:
    connection.connect()
    channel = connection.channel()
    channel.queue_declare(queue=queue_name, durable=False, auto_delete=True)
    channel.basic_publish(
        Message(body),
        exchange="",
        routing_key=queue_name,
    )

    received_message = channel.basic_get(
        queue=queue_name,
        no_ack=True,
    )
    assert received_message is not None, "RabbitMQ returned no message from the test queue"
    assert received_message.body == body, "Consumed message did not match published message"
    channel.queue_delete(queue=queue_name)
finally:
    connection.close()

print("RabbitMQ AMQP publish/consume test passed")
