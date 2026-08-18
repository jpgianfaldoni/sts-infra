# Databricks notebook source
# Configure these values from `./infra output aws <environment.tfvars>`.
dbutils.widgets.text("bootstrap_servers", "")
dbutils.widgets.text("topic", "demo-events")
dbutils.widgets.text("secret_scope", "kafka")
dbutils.widgets.text("username_key", "username")
dbutils.widgets.text("password_key", "password")

bootstrap_servers = dbutils.widgets.get("bootstrap_servers")
topic = dbutils.widgets.get("topic")
secret_scope = dbutils.widgets.get("secret_scope")
username = dbutils.secrets.get(secret_scope, dbutils.widgets.get("username_key"))
password = dbutils.secrets.get(secret_scope, dbutils.widgets.get("password_key"))

if not bootstrap_servers:
    raise ValueError("Set bootstrap_servers to the host:port for this compute path.")

jaas = (
    "org.apache.kafka.common.security.plain.PlainLoginModule required "
    f'username="{username}" password="{password}";'
)

events = (
    spark.readStream.format("kafka")
    .option("kafka.bootstrap.servers", bootstrap_servers)
    .option("subscribe", topic)
    .option("startingOffsets", "latest")
    .option("kafka.security.protocol", "SASL_PLAINTEXT")
    .option("kafka.sasl.mechanism", "PLAIN")
    .option("kafka.sasl.jaas.config", jaas)
    .load()
    .selectExpr(
        "CAST(key AS STRING) AS event_key",
        "CAST(value AS STRING) AS event_json",
        "timestamp AS kafka_timestamp",
        "partition",
        "offset",
    )
)

display(events)
