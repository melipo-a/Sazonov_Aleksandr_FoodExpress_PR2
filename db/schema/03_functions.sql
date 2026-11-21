CREATE PROCEDURE sazonov_food.add_product(
    p_product_name varchar,
    p_product_category_id uuid,
    p_price numeric,
    p_restaurant_id uuid,
    p_photo_url text,
    p_rating numeric,
    p_status sazonov_food.product_status,
    p_description text
) AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM sazonov_food.restaurant
        WHERE restaurant_id = p_restaurant_id
    ) THEN
        RAISE EXCEPTION 'Ресторан с ID % не найден', p_restaurant_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM sazonov_food.product_category
        WHERE product_category_id = p_product_category_id
    ) THEN
        RAISE EXCEPTION 'Категория с ID % не найдена', p_product_category_id;
    END IF;

    INSERT INTO sazonov_food.product (
        product_name, product_category_id, price, restaurant_id,
        photo_url, rating, status, description
    ) VALUES (
        p_product_name, p_product_category_id, p_price, p_restaurant_id,
        p_photo_url, p_rating, p_status, p_description
    );
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION sazonov_food.rating_change() RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'DELETE'
       OR (TG_OP = 'UPDATE'
           AND (OLD.entity_type <> NEW.entity_type OR OLD.entity_id <> NEW.entity_id)) THEN
        IF OLD.entity_type = 'блюдо' THEN
            UPDATE sazonov_food.product p
            SET rating = (
                SELECT avg(r.rating)
                FROM sazonov_food.review r
                WHERE r.entity_type = 'блюдо' AND r.entity_id = OLD.entity_id
            )
            WHERE p.product_id = OLD.entity_id;
        ELSIF OLD.entity_type = 'ресторан' THEN
            UPDATE sazonov_food.restaurant t
            SET rating = (
                SELECT avg(r.rating)
                FROM sazonov_food.review r
                WHERE r.entity_type = 'ресторан' AND r.entity_id = OLD.entity_id
            )
            WHERE t.restaurant_id = OLD.entity_id;
        END IF;
    END IF;

    IF TG_OP IN ('INSERT', 'UPDATE') THEN
        IF NEW.entity_type = 'блюдо' THEN
            UPDATE sazonov_food.product p
            SET rating = (
                SELECT avg(r.rating)
                FROM sazonov_food.review r
                WHERE r.entity_type = 'блюдо' AND r.entity_id = NEW.entity_id
            )
            WHERE p.product_id = NEW.entity_id;
        ELSIF NEW.entity_type = 'ресторан' THEN
            UPDATE sazonov_food.restaurant t
            SET rating = (
                SELECT avg(r.rating)
                FROM sazonov_food.review r
                WHERE r.entity_type = 'ресторан' AND r.entity_id = NEW.entity_id
            )
            WHERE t.restaurant_id = NEW.entity_id;
        END IF;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER rating_change_trigger
AFTER INSERT OR UPDATE OR DELETE ON sazonov_food.review
FOR EACH ROW EXECUTE FUNCTION sazonov_food.rating_change();

CREATE PROCEDURE sazonov_food.courier_salary() AS $$
DECLARE
    v_courier record;
    v_month timestamp := date_trunc('month', current_timestamp)::timestamp;
    v_year integer := extract(year from current_timestamp)::integer;
    v_month_no integer := extract(month from current_timestamp)::integer;
    v_delivered bigint;
    v_total_commission numeric;
    v_current_coefficient numeric;
    v_next_coefficient numeric;
BEGIN
    FOR v_courier IN
        SELECT courier_id, status, coefficient
        FROM sazonov_food.courier
    LOOP
        SELECT count(*), coalesce(sum(commission), 0)
        INTO v_delivered, v_total_commission
        FROM sazonov_food."order"
        WHERE courier_id = v_courier.courier_id
          AND status = 'доставлен'
          AND delivery_timestamp >= v_month
          AND delivery_timestamp < v_month + interval '1 month';

        SELECT coefficient_used INTO v_current_coefficient
        FROM sazonov_food.courier_pay
        WHERE courier_id = v_courier.courier_id
          AND year = v_year AND month = v_month_no;

        v_next_coefficient := CASE
            WHEN v_delivered <= 150 THEN 0.10
            WHEN v_delivered <= 250 THEN 0.20
            WHEN v_delivered <= 500 THEN 0.30
            ELSE 0.50
        END;

        IF v_current_coefficient IS NULL THEN
            v_current_coefficient := v_courier.coefficient;
            INSERT INTO sazonov_food.courier_pay (
                year, month, courier_id, amount, coefficient_used
            ) VALUES (
                v_year, v_month_no, v_courier.courier_id,
                round(v_total_commission * v_current_coefficient, 2),
                v_current_coefficient
            );
        ELSE
            UPDATE sazonov_food.courier_pay
            SET amount = round(v_total_commission * v_current_coefficient, 2)
            WHERE courier_id = v_courier.courier_id
              AND year = v_year AND month = v_month_no;
        END IF;

        IF v_courier.status <> 'уволен' THEN
            UPDATE sazonov_food.courier
            SET coefficient = v_next_coefficient
            WHERE courier_id = v_courier.courier_id;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;
