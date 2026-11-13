-- Sample data for the lab MySQL database. ./infra verify runs it through the
-- lab check job; it is idempotent and matches the other sample databases.
-- No JSON or spatial columns: Lakeflow Connect skips tables that have them.

CREATE TABLE IF NOT EXISTS customers
(
    customer_id INT NOT NULL,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) NOT NULL,
    created_at DATETIME NOT NULL,
    PRIMARY KEY (customer_id),
    UNIQUE KEY uq_customers_email (email)
) ENGINE = InnoDB;

CREATE TABLE IF NOT EXISTS orders
(
    order_id INT NOT NULL,
    customer_id INT NOT NULL,
    order_date DATE NOT NULL,
    amount DECIMAL(10, 2) NOT NULL,
    status VARCHAR(20) NOT NULL,
    PRIMARY KEY (order_id),
    CONSTRAINT fk_orders_customers FOREIGN KEY (customer_id) REFERENCES customers (customer_id),
    CONSTRAINT ck_orders_amount_nonnegative CHECK (amount >= 0),
    CONSTRAINT ck_orders_status CHECK (status IN ('pending', 'paid', 'shipped', 'cancelled'))
) ENGINE = InnoDB;

INSERT INTO customers (customer_id, name, email, created_at)
VALUES
    (1, 'Ana Silva', 'ana.silva@example.com', '2026-01-10 09:30:00'),
    (2, 'Bruno Costa', 'bruno.costa@example.com', '2026-02-14 14:15:00'),
    (3, 'Carla Souza', 'carla.souza@example.com', '2026-03-21 11:00:00') AS source
ON DUPLICATE KEY UPDATE
    name = source.name,
    email = source.email,
    created_at = source.created_at;

INSERT INTO orders (order_id, customer_id, order_date, amount, status)
VALUES
    (1001, 1, '2026-04-01', 149.90, 'paid'),
    (1002, 1, '2026-04-07', 79.50, 'shipped'),
    (1003, 2, '2026-04-11', 320.00, 'pending'),
    (1004, 3, '2026-04-15', 45.99, 'paid'),
    (1005, 3, '2026-04-18', 210.25, 'cancelled') AS source
ON DUPLICATE KEY UPDATE
    customer_id = source.customer_id,
    order_date = source.order_date,
    amount = source.amount,
    status = source.status;
