SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.customers', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.customers
    (
        customer_id INT NOT NULL,
        name NVARCHAR(100) NOT NULL,
        email NVARCHAR(255) NOT NULL,
        created_at DATETIME2(0) NOT NULL,
        CONSTRAINT PK_customers PRIMARY KEY (customer_id),
        CONSTRAINT UQ_customers_email UNIQUE (email)
    );
END;

IF OBJECT_ID(N'dbo.orders', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.orders
    (
        order_id INT NOT NULL,
        customer_id INT NOT NULL,
        order_date DATE NOT NULL,
        amount DECIMAL(10, 2) NOT NULL,
        status NVARCHAR(20) NOT NULL,
        CONSTRAINT PK_orders PRIMARY KEY (order_id),
        CONSTRAINT FK_orders_customers
            FOREIGN KEY (customer_id) REFERENCES dbo.customers (customer_id),
        CONSTRAINT CK_orders_amount_nonnegative CHECK (amount >= 0),
        CONSTRAINT CK_orders_status
            CHECK (status IN (N'pending', N'paid', N'shipped', N'cancelled'))
    );
END;

MERGE dbo.customers WITH (HOLDLOCK) AS target
USING
(
    VALUES
        (1, N'Ana Silva', N'ana.silva@example.com', CAST('2026-01-10T09:30:00' AS DATETIME2(0))),
        (2, N'Bruno Costa', N'bruno.costa@example.com', CAST('2026-02-14T14:15:00' AS DATETIME2(0))),
        (3, N'Carla Souza', N'carla.souza@example.com', CAST('2026-03-21T11:00:00' AS DATETIME2(0)))
) AS source (customer_id, name, email, created_at)
ON target.customer_id = source.customer_id
WHEN MATCHED THEN
    UPDATE SET
        name = source.name,
        email = source.email,
        created_at = source.created_at
WHEN NOT MATCHED BY TARGET THEN
    INSERT (customer_id, name, email, created_at)
    VALUES (source.customer_id, source.name, source.email, source.created_at);

MERGE dbo.orders WITH (HOLDLOCK) AS target
USING
(
    VALUES
        (1001, 1, CAST('2026-04-01' AS DATE), CAST(149.90 AS DECIMAL(10, 2)), N'paid'),
        (1002, 1, CAST('2026-04-07' AS DATE), CAST(79.50 AS DECIMAL(10, 2)), N'shipped'),
        (1003, 2, CAST('2026-04-11' AS DATE), CAST(320.00 AS DECIMAL(10, 2)), N'pending'),
        (1004, 3, CAST('2026-04-15' AS DATE), CAST(45.99 AS DECIMAL(10, 2)), N'paid'),
        (1005, 3, CAST('2026-04-18' AS DATE), CAST(210.25 AS DECIMAL(10, 2)), N'cancelled')
) AS source (order_id, customer_id, order_date, amount, status)
ON target.order_id = source.order_id
WHEN MATCHED THEN
    UPDATE SET
        customer_id = source.customer_id,
        order_date = source.order_date,
        amount = source.amount,
        status = source.status
WHEN NOT MATCHED BY TARGET THEN
    INSERT (order_id, customer_id, order_date, amount, status)
    VALUES (source.order_id, source.customer_id, source.order_date, source.amount, source.status);

COMMIT TRANSACTION;

SELECT N'customers' AS table_name, COUNT(*) AS row_count
FROM dbo.customers
UNION ALL
SELECT N'orders' AS table_name, COUNT(*) AS row_count
FROM dbo.orders;
