# Протокол проверки FoodExpress

Сазонов Александр · 21.11.2026 · MacBook · PostgreSQL 17.11 (Homebrew, arm64) · `sazonov_food` · `inspector`.

## Установка

Из корня репозитория под пользователем с правами на создание базы, расширения и роли.

```bash
cd db/schema
FOOD_DB="foodexpress_pr2_$(date +%Y%m%d_%H%M%S)"
FOOD_RESTORE="${FOOD_DB}_restore"
createdb "$FOOD_DB" &&
psql -X -v ON_ERROR_STOP=1 -d "$FOOD_DB" -c 'CREATE SCHEMA exts' \
  -c 'CREATE EXTENSION "uuid-ossp" WITH SCHEMA exts' &&
psql -X -1 -v ON_ERROR_STOP=1 -d "$FOOD_DB" -f 00_install.sql &&
psql -X -U inspector -d "$FOOD_DB"
```

## Структура и права (FOOD-101, FOOD-109)

```sql
\set ON_ERROR_STOP on
SET search_path TO sazonov_food, exts;
SELECT current_user, session_user;
SELECT has_schema_privilege(current_user, 'sazonov_food', 'USAGE') AS usage,
       has_schema_privilege(current_user, 'sazonov_food', 'CREATE') AS create;
SELECT table_name, string_agg(privilege_type, ', ') AS privileges
FROM information_schema.role_table_grants
WHERE table_schema = 'sazonov_food' AND grantee = current_user
GROUP BY table_name;
```

В схеме 12 таблиц, 8 ENUM и 16 внешних ключей. Оба имени пользователя — `inspector`. Проверка G.1 вернула `t` для `USAGE` и `t` для `CREATE`. На каждой таблице доступны `SELECT`, `INSERT`, `UPDATE` и `DELETE`.

## Генерация и очистка (FOOD-102, FOOD-103)

1. В чистой схеме выполнить `CALL insert_test_data(10);`.
2. Выполнить `BEGIN;`, повторить вызов генератора и выполнить `ROLLBACK;`.
3. В новой транзакции дважды выполнить `CALL erase_test_data();`, затем `ROLLBACK;`.

После каждого вызова и отката проверить число строк.

```sql
SELECT 'address' AS table_name, count(*) AS n FROM address
UNION ALL SELECT 'client', count(*) FROM client
UNION ALL SELECT 'client_address', count(*) FROM client_address
UNION ALL SELECT 'courier', count(*) FROM courier
UNION ALL SELECT 'courier_pay', count(*) FROM courier_pay
UNION ALL SELECT 'order', count(*) FROM "order"
UNION ALL SELECT 'order_structure', count(*) FROM order_structure
UNION ALL SELECT 'payment', count(*) FROM payment
UNION ALL SELECT 'product', count(*) FROM product
UNION ALL SELECT 'product_category', count(*) FROM product_category
UNION ALL SELECT 'restaurant', count(*) FROM restaurant
UNION ALL SELECT 'review', count(*) FROM review
ORDER BY table_name;
```

| Таблицы | Первый вызов | Повторный вызов | Каждая очистка | После отката |
|---|---:|---:|---:|---:|
| `client`, `courier`, `product_category`, `restaurant` | 10 | 20 | 0 | 10 |
| `client_address` | 40 | 80 | 0 | 40 |
| `address`, `order`, `order_structure`, `payment`, `product`, `review` | 50 | 100 | 0 | 50 |
| `courier_pay` | 60 | 120 | 0 | 60 |

В архиве у всех 50 заказов адрес принадлежит клиенту, а блюда — ресторану заказа. Комиссия равна 10 % стоимости блюд, итог не ниже 1 000 ₽. У каждого заказа одна успешная оплата на итоговую сумму. [Проверки D.2–D.9](https://github.com/NKhashchanov/total_designing_db_2026/blob/94fad92fb401c95c5b85faf91eb35ed27dc3b34d/templates/tests.md#L290-L375).

## Добавление блюда (FOOD-104)

```sql
SELECT product_category_id AS cat, restaurant_id AS rest,
       'Проверочное блюдо ' || exts.uuid_generate_v4()::text AS name
FROM product LIMIT 1 \gset
BEGIN;
CALL add_product(:'name', :'cat', 1200, :'rest', NULL, NULL, 'доступно', 'Описание');
SELECT rating IS NULL AS without_rating
FROM product WHERE product_name = :'name' AND restaurant_id = :'rest';
ROLLBACK;
```

Для вставленного блюда получена одна строка с `without_rating = t`. При отдельном вызове с начальным рейтингом 4,5 сохранено значение 4,5.

```sql
\set ON_ERROR_STOP off
BEGIN;
CALL add_product(:'name', :'cat', -1, :'rest', NULL, NULL, 'доступно', 'Описание');
ROLLBACK;
BEGIN;
CALL add_product(:'name', '00000000-0000-0000-0000-000000000000', 1200,
                 :'rest', NULL, NULL, 'доступно', 'Описание');
ROLLBACK;
\set ON_ERROR_STOP on
SELECT count(*) FROM product WHERE product_name = :'name' AND restaurant_id = :'rest';
```

Отрицательная цена отклонена ограничением `product_price_nonnegative`. Для отсутствующей категории процедура выдала ошибку «Категория с ID … не найдена». После отката блюдо отсутствует.

## Рейтинги, статистика и выплаты (FOOD-105–108)

```sql
BEGIN;
SELECT review_id, entity_id AS dish FROM review WHERE entity_type = 'блюдо' LIMIT 1 \gset
DELETE FROM review WHERE review_id = :'review_id';
SELECT rating IS NULL AS without_rating FROM product WHERE product_id = :'dish';
ROLLBACK;
SELECT * FROM get_statistic();
BEGIN;
CALL courier_salary();
CALL courier_salary();
SELECT year, month, courier_id, amount, coefficient_used FROM courier_pay;
ROLLBACK;
SELECT * FROM how_much_money ORDER BY year_month;
\q
```

| Проверка | Результат |
|---|---|
| `rating_change` | Для оценок 3, 4 и 5 получен рейтинг 4. После удаления оценки 3 — 4,5, после удаления последнего отзыва — `NULL`. При переносе отзыва пересчитаны обе цели. |
| `get_statistic` | По одной строке на каждый из 10 ресторанов. В архиве у каждого три доставки на 6 710 ₽, средний чек — 2 236,67 ₽ при округлении до копеек. Блюдо и клиент входят в число лидеров по количеству проданных порций и числу доставленных заказов соответственно. |
| `courier_salary` | При 0 и 150 доставках ставка следующего месяца — 0,10, при 151 и 250 — 0,20, при 251 и 500 — 0,30, при 501 — 0,50. Выплаты сверены по месяцу `delivery_timestamp` и ставке текущего месяца. Повторный вызов за тот же месяц сохранил число записей. |
| `how_much_money` | В архиве шесть месяцев, с июня по ноябрь 2026 года. За июнь комиссия составила 480 ₽, выплата курьерам — 48 ₽, чистая прибыль — 432 ₽. В первом месяце предыдущая комиссия и разница равны `NULL`. В проверке с пропущенным месяцем он вошёл в отчёт с нулевой суммой заказов. |

## Восстановление (FOOD-110)

Из того же каталога `db/schema` восстановить приложенный архив в чистую базу.

```bash
createdb "$FOOD_RESTORE" &&
psql -X -v ON_ERROR_STOP=1 -d "$FOOD_RESTORE" -c 'CREATE SCHEMA exts' \
  -c 'CREATE EXTENSION "uuid-ossp" WITH SCHEMA exts' &&
pg_restore --exit-on-error --no-owner --no-acl -d "$FOOD_RESTORE" \
  ../foodexpress_sazonov.backup &&
psql -X -1 -v ON_ERROR_STOP=1 -d "$FOOD_RESTORE" -f grants.sql &&
psql -X -U inspector -d "$FOOD_RESTORE"
```

В новом сеансе повторить блок «Структура и права». До вызова генератора выполнить запрос подсчёта строк по 12 таблицам из раздела «Генерация и очистка».

```sql
BEGIN;
CALL insert_test_data(10);
SELECT count(*) FROM get_statistic();
ROLLBACK;
\q
```

После `pg_restore` и применения `grants.sql` вход под `inspector` успешен. Совпали определения объектов и все 440 строк базы, из которой сделан архив. После повторного вызова генератора в транзакции ожидаются 20 строк статистики.
