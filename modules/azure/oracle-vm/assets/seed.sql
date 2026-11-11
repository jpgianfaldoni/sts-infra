-- Sample data for the lab Oracle database. ./infra verify runs it through the
-- lab check job as the master user. Each block ends with a line holding only
-- a slash; every block is idempotent. The LAB schema has no password, so it
-- cannot sign in. No identity, BOOLEAN, or JSON columns: LogMiner skips them.

DECLARE
    found INTEGER;
BEGIN
    SELECT COUNT(*) INTO found FROM all_users WHERE username = 'LAB';
    IF found = 0 THEN
        EXECUTE IMMEDIATE 'CREATE USER LAB NO AUTHENTICATION DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS';
    END IF;
END;
/

DECLARE
    found INTEGER;
BEGIN
    SELECT COUNT(*) INTO found FROM all_tables WHERE owner = 'LAB' AND table_name = 'CUSTOMERS';
    IF found = 0 THEN
        EXECUTE IMMEDIATE q'[
            CREATE TABLE LAB.CUSTOMERS (
                CUSTOMER_ID NUMBER(10) NOT NULL,
                NAME VARCHAR2(100) NOT NULL,
                EMAIL VARCHAR2(255) NOT NULL,
                CREATED_AT TIMESTAMP(0) NOT NULL,
                CONSTRAINT PK_CUSTOMERS PRIMARY KEY (CUSTOMER_ID),
                CONSTRAINT UQ_CUSTOMERS_EMAIL UNIQUE (EMAIL)
            )]';
    END IF;
    SELECT COUNT(*) INTO found FROM all_tables WHERE owner = 'LAB' AND table_name = 'ORDERS';
    IF found = 0 THEN
        EXECUTE IMMEDIATE q'[
            CREATE TABLE LAB.ORDERS (
                ORDER_ID NUMBER(10) NOT NULL,
                CUSTOMER_ID NUMBER(10) NOT NULL,
                ORDER_DATE DATE NOT NULL,
                AMOUNT NUMBER(10, 2) NOT NULL,
                STATUS VARCHAR2(20) NOT NULL,
                CONSTRAINT PK_ORDERS PRIMARY KEY (ORDER_ID),
                CONSTRAINT FK_ORDERS_CUSTOMERS FOREIGN KEY (CUSTOMER_ID) REFERENCES LAB.CUSTOMERS (CUSTOMER_ID),
                CONSTRAINT CK_ORDERS_AMOUNT_NONNEGATIVE CHECK (AMOUNT >= 0),
                CONSTRAINT CK_ORDERS_STATUS CHECK (STATUS IN ('pending', 'paid', 'shipped', 'cancelled'))
            )]';
    END IF;
END;
/

BEGIN
    MERGE INTO LAB.CUSTOMERS target
    USING (
        SELECT 1 AS customer_id, 'Ana Silva' AS name, 'ana.silva@example.com' AS email, TIMESTAMP '2026-01-10 09:30:00' AS created_at FROM dual UNION ALL
        SELECT 2, 'Bruno Costa', 'bruno.costa@example.com', TIMESTAMP '2026-02-14 14:15:00' FROM dual UNION ALL
        SELECT 3, 'Carla Souza', 'carla.souza@example.com', TIMESTAMP '2026-03-21 11:00:00' FROM dual
    ) source
    ON (target.CUSTOMER_ID = source.customer_id)
    WHEN MATCHED THEN UPDATE SET target.NAME = source.name, target.EMAIL = source.email, target.CREATED_AT = source.created_at
    WHEN NOT MATCHED THEN INSERT (CUSTOMER_ID, NAME, EMAIL, CREATED_AT)
        VALUES (source.customer_id, source.name, source.email, source.created_at);

    MERGE INTO LAB.ORDERS target
    USING (
        SELECT 1001 AS order_id, 1 AS customer_id, DATE '2026-04-01' AS order_date, 149.90 AS amount, 'paid' AS status FROM dual UNION ALL
        SELECT 1002, 1, DATE '2026-04-07', 79.50, 'shipped' FROM dual UNION ALL
        SELECT 1003, 2, DATE '2026-04-11', 320.00, 'pending' FROM dual UNION ALL
        SELECT 1004, 3, DATE '2026-04-15', 45.99, 'paid' FROM dual UNION ALL
        SELECT 1005, 3, DATE '2026-04-18', 210.25, 'cancelled' FROM dual
    ) source
    ON (target.ORDER_ID = source.order_id)
    WHEN MATCHED THEN UPDATE SET target.CUSTOMER_ID = source.customer_id, target.ORDER_DATE = source.order_date,
        target.AMOUNT = source.amount, target.STATUS = source.status
    WHEN NOT MATCHED THEN INSERT (ORDER_ID, CUSTOMER_ID, ORDER_DATE, AMOUNT, STATUS)
        VALUES (source.order_id, source.customer_id, source.order_date, source.amount, source.status);
    COMMIT;
END;
/
