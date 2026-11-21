CREATE FUNCTION sazonov_food.get_statistic()
RETURNS TABLE (
    restaurant_name varchar,
    best_product_name varchar,
    total_amount numeric,
    avg_amount numeric,
    best_user varchar
) AS $$
BEGIN
RETURN QUERY
WITH delivered AS (
    SELECT o.order_id, o.restaurant_id, o.client_id, o.total_amount
    FROM sazonov_food."order" o
    WHERE o.status = 'доставлен'
),
restaurant_totals AS (
    SELECT d.restaurant_id, sum(d.total_amount) AS total_amount,
           avg(d.total_amount) AS avg_amount
    FROM delivered d
    GROUP BY d.restaurant_id
),
product_sales AS (
    SELECT d.restaurant_id, os.product_id, sum(os.quantity) AS quantity_sold
    FROM delivered d
    JOIN sazonov_food.order_structure os ON os.order_id = d.order_id
    GROUP BY d.restaurant_id, os.product_id
),
best_products AS (
    SELECT DISTINCT ON (ps.restaurant_id)
           ps.restaurant_id, p.product_name
    FROM product_sales ps
    JOIN sazonov_food.product p ON p.product_id = ps.product_id
    ORDER BY ps.restaurant_id, ps.quantity_sold DESC, random()
),
client_sales AS (
    SELECT restaurant_id, client_id, count(*) AS order_count
    FROM delivered
    GROUP BY restaurant_id, client_id
),
best_clients AS (
    SELECT DISTINCT ON (cs.restaurant_id)
           cs.restaurant_id, c.login
    FROM client_sales cs
    JOIN sazonov_food.client c ON c.client_id = cs.client_id
    ORDER BY cs.restaurant_id, cs.order_count DESC, random()
)
SELECT r.restaurant_name,
       bp.product_name,
       rt.total_amount,
       rt.avg_amount,
       bc.login
FROM sazonov_food.restaurant r
LEFT JOIN restaurant_totals rt ON rt.restaurant_id = r.restaurant_id
LEFT JOIN best_products bp ON bp.restaurant_id = r.restaurant_id
LEFT JOIN best_clients bc ON bc.restaurant_id = r.restaurant_id;
END;
$$ LANGUAGE plpgsql;

CREATE VIEW sazonov_food.how_much_money AS
WITH RECURSIVE boundaries AS (
    SELECT min(date_trunc('month', delivery_timestamp)) AS first_month,
           max(date_trunc('month', delivery_timestamp)) AS last_month
    FROM sazonov_food."order"
    WHERE status = 'доставлен'
),
months AS (
    SELECT first_month AS month_start, last_month
    FROM boundaries
    WHERE first_month IS NOT NULL
    UNION ALL
    SELECT month_start + interval '1 month', last_month
    FROM months
    WHERE month_start < last_month
),
order_totals AS (
    SELECT date_trunc('month', delivery_timestamp) AS month_start,
           sum(order_amount) AS sum_no_commission,
           sum(total_amount) AS sum_with_commission
    FROM sazonov_food."order"
    WHERE status = 'доставлен'
    GROUP BY date_trunc('month', delivery_timestamp)
),
salary_totals AS (
    SELECT date '0001-01-01' + (year - 1) * interval '1 year'
           + (month - 1) * interval '1 month' AS month_start,
           sum(amount) AS courier_pay
    FROM sazonov_food.courier_pay
    GROUP BY year, month
),
monthly AS (
    SELECT m.month_start,
           coalesce(o.sum_no_commission, 0) AS sum_no_commission,
           coalesce(o.sum_with_commission, 0) AS sum_with_commission,
           (coalesce(o.sum_with_commission, 0)
            - coalesce(o.sum_no_commission, 0)) AS commission,
           coalesce(s.courier_pay, 0) AS courier_pay
    FROM months m
    LEFT JOIN order_totals o ON o.month_start = m.month_start
    LEFT JOIN salary_totals s ON s.month_start = m.month_start
),
month_with_previous AS (
    SELECT month_start, sum_no_commission, sum_with_commission,
           commission,
           lag(commission) OVER (ORDER BY month_start) AS prev_commission,
           courier_pay
    FROM monthly
)
SELECT CASE
           WHEN extract(year from month_start) < 10 THEN '000'
           WHEN extract(year from month_start) < 100 THEN '00'
           WHEN extract(year from month_start) < 1000 THEN '0'
           ELSE ''
       END || extract(year from month_start)::text || '-'
       || CASE WHEN extract(month from month_start) < 10 THEN '0' ELSE '' END
       || extract(month from month_start)::text AS year_month,
       sum_no_commission,
       sum_with_commission,
       commission,
       prev_commission,
       commission - prev_commission AS commission_diff,
       courier_pay,
       commission - courier_pay AS net_profit
FROM month_with_previous;
