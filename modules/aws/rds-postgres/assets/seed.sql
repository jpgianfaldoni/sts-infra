-- Sample data for the lab PostgreSQL database. ./infra verify runs it through
-- the lab check job; it is idempotent and matches the SQL Server sample data.

CREATE TABLE IF NOT EXISTS public.customers
(
    customer_id INTEGER NOT NULL,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) NOT NULL,
    created_at TIMESTAMP(0) NOT NULL,
    CONSTRAINT pk_customers PRIMARY KEY (customer_id),
    CONSTRAINT uq_customers_email UNIQUE (email)
);

CREATE TABLE IF NOT EXISTS public.orders
(
    order_id INTEGER NOT NULL,
    customer_id INTEGER NOT NULL,
    order_date DATE NOT NULL,
    amount NUMERIC(10, 2) NOT NULL,
    status VARCHAR(20) NOT NULL,
    CONSTRAINT pk_orders PRIMARY KEY (order_id),
    CONSTRAINT fk_orders_customers
        FOREIGN KEY (customer_id) REFERENCES public.customers (customer_id),
    CONSTRAINT ck_orders_amount_nonnegative CHECK (amount >= 0),
    CONSTRAINT ck_orders_status CHECK (status IN ('pending', 'paid', 'shipped', 'cancelled'))
);

INSERT INTO public.customers (customer_id, name, email, created_at)
VALUES
    (1, 'Ana Silva', 'ana.silva@example.com', TIMESTAMP '2026-01-10 09:30:00'),
    (2, 'Bruno Costa', 'bruno.costa@example.com', TIMESTAMP '2026-02-14 14:15:00'),
    (3, 'Carla Souza', 'carla.souza@example.com', TIMESTAMP '2026-03-21 11:00:00')
ON CONFLICT (customer_id) DO UPDATE SET
    name = EXCLUDED.name,
    email = EXCLUDED.email,
    created_at = EXCLUDED.created_at;

INSERT INTO public.orders (order_id, customer_id, order_date, amount, status)
VALUES
    (1001, 1, DATE '2026-04-01', 149.90, 'paid'),
    (1002, 1, DATE '2026-04-07', 79.50, 'shipped'),
    (1003, 2, DATE '2026-04-11', 320.00, 'pending'),
    (1004, 3, DATE '2026-04-15', 45.99, 'paid'),
    (1005, 3, DATE '2026-04-18', 210.25, 'cancelled')
ON CONFLICT (order_id) DO UPDATE SET
    customer_id = EXCLUDED.customer_id,
    order_date = EXCLUDED.order_date,
    amount = EXCLUDED.amount,
    status = EXCLUDED.status;
