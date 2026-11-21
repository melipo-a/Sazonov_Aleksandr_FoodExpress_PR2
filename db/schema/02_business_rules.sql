CREATE FUNCTION sazonov_food.check_order_structure() RETURNS trigger AS $$
DECLARE
    v_order_restaurant uuid;
    v_product_restaurant uuid;
BEGIN
    IF TG_OP IN ('UPDATE', 'DELETE') THEN
        IF TG_OP = 'DELETE' OR OLD.order_id <> NEW.order_id
           OR OLD.product_id <> NEW.product_id THEN
            IF EXISTS (
                SELECT 1 FROM sazonov_food.review
                WHERE order_id = OLD.order_id AND entity_type = 'блюдо'
                  AND entity_id = OLD.product_id
            ) THEN
                RAISE EXCEPTION 'Нельзя убрать из заказа блюдо, на которое есть отзыв';
            END IF;
        END IF;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;

    SELECT restaurant_id INTO v_order_restaurant
    FROM sazonov_food."order"
    WHERE order_id = NEW.order_id;

    SELECT restaurant_id INTO v_product_restaurant
    FROM sazonov_food.product
    WHERE product_id = NEW.product_id;

    IF v_order_restaurant <> v_product_restaurant THEN
        RAISE EXCEPTION 'Блюдо должно принадлежать ресторану заказа';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER check_order_structure_trigger
AFTER INSERT OR UPDATE OF order_id, product_id OR DELETE ON sazonov_food.order_structure
FOR EACH ROW EXECUTE FUNCTION sazonov_food.check_order_structure();

CREATE FUNCTION sazonov_food.check_restaurant_consistency() RETURNS trigger AS $$
BEGIN
    IF TG_TABLE_NAME = 'product' THEN
        IF EXISTS (
            SELECT 1
            FROM sazonov_food.order_structure os
            JOIN sazonov_food."order" o ON o.order_id = os.order_id
            WHERE os.product_id = NEW.product_id
              AND o.restaurant_id <> NEW.restaurant_id
        ) THEN
            RAISE EXCEPTION 'Нельзя переносить заказанное блюдо в другой ресторан';
        END IF;
    ELSIF TG_TABLE_NAME = 'order' THEN
        IF OLD.restaurant_id <> NEW.restaurant_id THEN
            IF EXISTS (
                SELECT 1
                FROM sazonov_food.order_structure os
                JOIN sazonov_food.product p ON p.product_id = os.product_id
                WHERE os.order_id = NEW.order_id
                  AND p.restaurant_id <> NEW.restaurant_id
            ) THEN
                RAISE EXCEPTION 'В заказе есть блюда другого ресторана';
            END IF;
        END IF;

        IF EXISTS (
            SELECT 1 FROM sazonov_food.review r
            WHERE r.order_id = NEW.order_id
              AND (r.client_id <> NEW.client_id
                   OR (r.entity_type = 'ресторан' AND r.entity_id <> NEW.restaurant_id))
        ) THEN
            RAISE EXCEPTION 'Изменение заказа нарушает принадлежность существующего отзыва';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER product_restaurant_consistency_trigger
BEFORE UPDATE OF restaurant_id ON sazonov_food.product
FOR EACH ROW EXECUTE FUNCTION sazonov_food.check_restaurant_consistency();

CREATE TRIGGER order_restaurant_consistency_trigger
BEFORE UPDATE OF restaurant_id, client_id ON sazonov_food."order"
FOR EACH ROW EXECUTE FUNCTION sazonov_food.check_restaurant_consistency();

CREATE FUNCTION sazonov_food.check_review_target() RETURNS trigger AS $$
DECLARE
    v_client_id uuid;
    v_restaurant_id uuid;
BEGIN
    SELECT client_id, restaurant_id
    INTO v_client_id, v_restaurant_id
    FROM sazonov_food."order"
    WHERE order_id = NEW.order_id;

    IF v_client_id <> NEW.client_id THEN
        RAISE EXCEPTION 'Отзыв может оставить только клиент заказа';
    END IF;

    IF NEW.entity_type = 'заказ' THEN
        IF NEW.entity_id <> NEW.order_id THEN
            RAISE EXCEPTION 'Отзыв о заказе должен ссылаться на свой заказ';
        END IF;
    ELSIF NEW.entity_type = 'ресторан' THEN
        IF NEW.entity_id <> v_restaurant_id THEN
            RAISE EXCEPTION 'Нельзя оставить отзыв о чужом ресторане';
        END IF;
    ELSIF NEW.entity_type = 'блюдо' THEN
        IF NOT EXISTS (
            SELECT 1 FROM sazonov_food.order_structure os
            WHERE os.order_id = NEW.order_id
              AND os.product_id = NEW.entity_id
        ) THEN
            RAISE EXCEPTION 'Нельзя оставить отзыв о блюде вне заказа';
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER check_review_target_trigger
AFTER INSERT OR UPDATE OF client_id, order_id, entity_id, entity_type ON sazonov_food.review
FOR EACH ROW EXECUTE FUNCTION sazonov_food.check_review_target();

CREATE FUNCTION sazonov_food.check_payment_amount() RETURNS trigger AS $$
DECLARE
    v_total numeric;
BEGIN
    SELECT total_amount INTO v_total
    FROM sazonov_food."order"
    WHERE order_id = NEW.order_id;

    IF v_total <> NEW.amount THEN
        RAISE EXCEPTION 'Сумма оплаты не совпадает с общей суммой заказа';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER check_payment_amount_trigger
AFTER INSERT OR UPDATE OF order_id, amount ON sazonov_food.payment
FOR EACH ROW EXECUTE FUNCTION sazonov_food.check_payment_amount();

CREATE FUNCTION sazonov_food.check_order_amount_after_payment() RETURNS trigger AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM sazonov_food.payment p
        WHERE p.order_id = NEW.order_id AND p.amount <> NEW.total_amount
    ) THEN
        RAISE EXCEPTION 'Нельзя изменить сумму заказа вопреки существующим платежам';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER check_order_amount_after_payment_trigger
BEFORE UPDATE OF total_amount ON sazonov_food."order"
FOR EACH ROW EXECUTE FUNCTION sazonov_food.check_order_amount_after_payment();

CREATE FUNCTION sazonov_food.refresh_order_pay_status(p_order_id uuid) RETURNS void AS $$
DECLARE
    v_status sazonov_food.order_pay_status;
BEGIN
    SELECT CASE
        WHEN count(*) FILTER (WHERE status = 'успех') > 0
            THEN 'оплачен'::sazonov_food.order_pay_status
        WHEN count(*) > 0 AND count(*) FILTER (WHERE status = 'ошибка') = count(*)
            THEN 'ошибка'::sazonov_food.order_pay_status
        ELSE 'ожидает'::sazonov_food.order_pay_status
    END
    INTO v_status
    FROM sazonov_food.payment
    WHERE order_id = p_order_id;

    UPDATE sazonov_food."order"
    SET pay_status = v_status
    WHERE order_id = p_order_id;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION sazonov_food.payment_status_change() RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM sazonov_food.refresh_order_pay_status(OLD.order_id);
    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.order_id <> NEW.order_id THEN
            PERFORM sazonov_food.refresh_order_pay_status(OLD.order_id);
        END IF;
        PERFORM sazonov_food.refresh_order_pay_status(NEW.order_id);
    ELSE
        PERFORM sazonov_food.refresh_order_pay_status(NEW.order_id);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER payment_status_change_trigger
AFTER INSERT OR UPDATE OF status, order_id OR DELETE ON sazonov_food.payment
FOR EACH ROW EXECUTE FUNCTION sazonov_food.payment_status_change();

CREATE FUNCTION sazonov_food.check_order_pay_status() RETURNS trigger AS $$
DECLARE
    v_expected sazonov_food.order_pay_status;
BEGIN
    IF TG_OP = 'INSERT' AND NEW.pay_status = 'ожидает' THEN
        RETURN NEW;
    END IF;

    SELECT CASE
        WHEN count(*) FILTER (WHERE status = 'успех') > 0
            THEN 'оплачен'::sazonov_food.order_pay_status
        WHEN count(*) > 0 AND count(*) FILTER (WHERE status = 'ошибка') = count(*)
            THEN 'ошибка'::sazonov_food.order_pay_status
        ELSE 'ожидает'::sazonov_food.order_pay_status
    END
    INTO v_expected
    FROM sazonov_food.payment
    WHERE order_id = NEW.order_id;

    IF NEW.pay_status <> v_expected THEN
        RAISE EXCEPTION 'Статус оплаты заказа должен соответствовать попыткам оплаты';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER check_order_pay_status_trigger
BEFORE INSERT OR UPDATE OF pay_status ON sazonov_food."order"
FOR EACH ROW EXECUTE FUNCTION sazonov_food.check_order_pay_status();

CREATE FUNCTION sazonov_food.check_order_has_items() RETURNS trigger AS $$
DECLARE
    v_order_id uuid;
BEGIN
    IF TG_TABLE_NAME = 'order' THEN
        v_order_id := NEW.order_id;
    ELSE
        v_order_id := OLD.order_id;
    END IF;

    IF EXISTS (SELECT 1 FROM sazonov_food."order" WHERE order_id = v_order_id)
       AND NOT EXISTS (
           SELECT 1 FROM sazonov_food.order_structure WHERE order_id = v_order_id
       ) THEN
        RAISE EXCEPTION 'Заказ должен содержать хотя бы одну позицию';
    END IF;

    IF TG_TABLE_NAME = 'order' AND TG_OP = 'INSERT' THEN
        IF NEW.order_amount <> (
            SELECT round(sum(os.quantity * p.price), 2)
            FROM sazonov_food.order_structure os
            JOIN sazonov_food.product p ON p.product_id = os.product_id
            WHERE os.order_id = v_order_id
        ) THEN
            RAISE EXCEPTION 'Стоимость блюд не совпадает с первоначальным составом заказа';
        END IF;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER order_has_items_trigger
AFTER INSERT OR UPDATE OF order_id ON sazonov_food."order"
FOR EACH ROW EXECUTE FUNCTION sazonov_food.check_order_has_items();

CREATE TRIGGER order_structure_has_items_trigger
AFTER UPDATE OF order_id OR DELETE ON sazonov_food.order_structure
FOR EACH ROW EXECUTE FUNCTION sazonov_food.check_order_has_items();
