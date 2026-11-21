CREATE PROCEDURE sazonov_food.insert_test_data(value integer) AS $$
DECLARE
    v_token text;
    v_client_phone varchar(20);
    v_client_id uuid;
    v_courier_id uuid;
    v_restaurant_id uuid;
    v_restaurant_address_id uuid;
    v_client_address_id uuid;
    v_category_id uuid;
    v_product_id uuid;
    v_order_id uuid;
    v_order_time timestamp;
    v_delivery_time timestamp;
    v_review_entity_id uuid;
    v_review_type sazonov_food.review_entity_type;
    v_order_status sazonov_food.order_status;
    v_product_price numeric(12, 2);
    v_quantity numeric(12, 3);
    v_order_amount numeric(14, 2);
    v_commission numeric(14, 2);
    v_first_day date := (date_trunc('month', current_date) - interval '5 months')::date;
    v_month timestamp;
    v_count bigint;
    v_sum_commission numeric;
    v_coefficient numeric;
    v_order_statuses sazonov_food.order_status[] := enum_range(NULL::sazonov_food.order_status);
    v_product_statuses sazonov_food.product_status[] := enum_range(NULL::sazonov_food.product_status);
    v_courier_statuses sazonov_food.courier_status[] := enum_range(NULL::sazonov_food.courier_status);
    v_payment_types sazonov_food.payment_type[] := enum_range(NULL::sazonov_food.payment_type);
    v_payment_statuses sazonov_food.payment_status[] := enum_range(NULL::sazonov_food.payment_status);
    v_order_pay_statuses sazonov_food.order_pay_status[] := enum_range(NULL::sazonov_food.order_pay_status);
    v_restaurant_statuses sazonov_food.restaurant_status[] := enum_range(NULL::sazonov_food.restaurant_status);
    v_review_types sazonov_food.review_entity_type[] := enum_range(NULL::sazonov_food.review_entity_type);
BEGIN
    IF value IS NULL OR value <= 0 THEN
        RAISE EXCEPTION 'Параметр value должен быть положительным целым числом';
    END IF;
    IF v_first_day < current_date - 179 THEN
        v_first_day := current_date - 179;
    END IF;

    FOR i IN 1..value LOOP
        v_token := replace(exts.uuid_generate_v4()::text, '-', '');
        LOOP
            v_client_phone := '7' || (1000000000 + floor(random() * 9000000000))::bigint::text;
            EXIT WHEN NOT EXISTS (
                SELECT 1 FROM sazonov_food.client
                WHERE phone_number = v_client_phone
            );
        END LOOP;

        INSERT INTO sazonov_food.client (login, password, phone_number)
        VALUES (
            'клиент_' || v_client_phone,
            md5(random()::text),
            v_client_phone
        ) RETURNING client_id INTO v_client_id;

        INSERT INTO sazonov_food.courier (
            fio, phone_number, status, hire_date
        ) VALUES (
            (ARRAY['Иванов Иван Сергеевич', 'Смирнова Анна Олеговна',
                   'Волков Павел Андреевич'])[1 + ((i - 1) % 3)],
            '7' || (1000000000 + floor(random() * 9000000000))::bigint::text,
            v_courier_statuses[1 + ((i - 1) % 3)],
            v_first_day
        ) RETURNING courier_id INTO v_courier_id;

        INSERT INTO sazonov_food.product_category (product_category_name)
        VALUES ('Категория ' || i)
        RETURNING product_category_id INTO v_category_id;

        INSERT INTO sazonov_food.address (street, house_number, apartment_office)
        VALUES ('Улица ресторана ' || v_client_phone, '1', NULL)
        RETURNING address_id INTO v_restaurant_address_id;

        INSERT INTO sazonov_food.restaurant (
            restaurant_name, address_id, description,
            work_start, work_end, company_details, status
        ) VALUES (
            'Ресторан ' || i,
            v_restaurant_address_id,
            'Ресторан доставки еды',
            '09:00'::time, '23:00'::time,
            'Реквизиты ресторана ' || i,
            v_restaurant_statuses[1]
        ) RETURNING restaurant_id INTO v_restaurant_id;

        FOR j IN 1..5 LOOP
            IF j <= 4 THEN
                INSERT INTO sazonov_food.address (street, house_number, apartment_office)
                VALUES (
                    'Улица клиента ' || v_client_phone, '2',
                    CASE WHEN j = 4 THEN NULL ELSE j::text END
                ) RETURNING address_id INTO v_client_address_id;

                INSERT INTO sazonov_food.client_address (client_id, address_id)
                VALUES (v_client_id, v_client_address_id);
            END IF;

            v_product_price := 2000 + j * 200;
            v_quantity := CASE WHEN j = 1 THEN 0.5 ELSE 1 END;
            v_order_amount := round(v_product_price * v_quantity, 2);
            v_commission := round(v_order_amount * 0.10, 2);

            INSERT INTO sazonov_food.product (
                product_name, product_category_id, price, restaurant_id,
                photo_url, status, description
            ) VALUES (
                (ARRAY['Щи', 'Плов', 'Жаркое', 'Запеканка', 'Котлеты'])[j],
                v_category_id, v_product_price, v_restaurant_id,
                CASE WHEN j % 2 = 0 THEN NULL
                     ELSE 'https://example.org/products/' || v_token || '/' || j END,
                v_product_statuses[1 + ((j - 1) % 3)],
                'Описание блюда'
            ) RETURNING product_id INTO v_product_id;

            v_order_time := v_first_day::timestamp
                + random() * (localtimestamp - v_first_day::timestamp - interval '2 hours');

            IF j <= 3 THEN
                v_order_status := v_order_statuses[4];
                v_delivery_time := v_order_time + interval '1 hour';
            ELSIF j = 4 THEN
                v_order_status := v_order_statuses[3];
                v_delivery_time := NULL;
            ELSE
                v_order_status := v_order_statuses[5];
                v_delivery_time := NULL;
            END IF;

            WITH new_order AS (
                INSERT INTO sazonov_food."order" (
                    courier_id, client_id, address_id, restaurant_id,
                    order_timestamp, delivery_timestamp, order_amount,
                    commission, total_amount, status, pay_status, description
                ) VALUES (
                    v_courier_id, v_client_id, v_client_address_id,
                    v_restaurant_id, v_order_time, v_delivery_time,
                    v_order_amount, v_commission, v_order_amount + v_commission,
                    v_order_status, v_order_pay_statuses[1], 'Заказ тестовых данных'
                ) RETURNING order_id
            )
            INSERT INTO sazonov_food.order_structure (order_id, product_id, quantity)
            SELECT order_id, v_product_id, v_quantity FROM new_order
            RETURNING order_id INTO v_order_id;

            INSERT INTO sazonov_food.payment (
                order_id, payment_type, amount,
                transaction_id, transaction_timestamp, status
            ) VALUES (
                v_order_id, v_payment_types[1 + ((j - 1) % 3)],
                v_order_amount + v_commission,
                'tx_' || replace(exts.uuid_generate_v4()::text, '-', ''),
                v_order_time + interval '5 minutes',
                v_payment_statuses[1]
            );

            v_review_type := v_review_types[1 + ((j - 1) % 3)];
            IF v_review_type = 'блюдо' THEN
                v_review_entity_id := v_product_id;
            ELSIF v_review_type = 'ресторан' THEN
                v_review_entity_id := v_restaurant_id;
            ELSE
                v_review_entity_id := v_order_id;
            END IF;

            INSERT INTO sazonov_food.review (
                client_id, review_timestamp, entity_id, entity_type,
                order_id, description, photo_url, rating
            ) VALUES (
                v_client_id, v_order_time + interval '2 hours',
                v_review_entity_id, v_review_type, v_order_id,
                'Отзыв тестовых данных', NULL, 1 + ((j - 1) % 5)
            );
        END LOOP;
        v_coefficient := 0.10;
        FOR m IN 0..5 LOOP
            v_month := (date_trunc('month', current_timestamp)
                        - (5 - m) * interval '1 month')::timestamp;

            SELECT count(*), coalesce(sum(commission), 0)
            INTO v_count, v_sum_commission
            FROM sazonov_food."order"
            WHERE courier_id = v_courier_id
              AND status = 'доставлен'
              AND delivery_timestamp >= v_month
              AND delivery_timestamp < v_month + interval '1 month';

            INSERT INTO sazonov_food.courier_pay (
                year, month, courier_id, amount, coefficient_used
            ) VALUES (
                extract(year from v_month)::integer,
                extract(month from v_month)::integer,
                v_courier_id,
                round(v_coefficient * v_sum_commission, 2),
                v_coefficient
            );

            v_coefficient := CASE
                WHEN v_count <= 150 THEN 0.10
                WHEN v_count <= 250 THEN 0.20
                WHEN v_count <= 500 THEN 0.30
                ELSE 0.50
            END;
        END LOOP;

        UPDATE sazonov_food.courier
        SET coefficient = v_coefficient
        WHERE courier_id = v_courier_id AND status <> 'уволен';
    END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE PROCEDURE sazonov_food.erase_test_data() AS $$
BEGIN
    DELETE FROM sazonov_food.review;
    DELETE FROM sazonov_food.payment;
    DELETE FROM sazonov_food.courier_pay;
    WITH removed_orders AS (
        DELETE FROM sazonov_food."order" RETURNING order_id
    )
    DELETE FROM sazonov_food.order_structure
    WHERE order_id IN (SELECT order_id FROM removed_orders);
    DELETE FROM sazonov_food.product;
    DELETE FROM sazonov_food.product_category;
    DELETE FROM sazonov_food.client_address;
    DELETE FROM sazonov_food.restaurant;
    DELETE FROM sazonov_food.courier;
    DELETE FROM sazonov_food.client;
    DELETE FROM sazonov_food.address;
END;
$$ LANGUAGE plpgsql;
