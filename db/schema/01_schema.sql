CREATE SCHEMA sazonov_food;

CREATE TYPE sazonov_food.restaurant_status AS ENUM ('активен', 'неактивен');
CREATE TYPE sazonov_food.product_status AS ENUM ('доступно', 'нет_в_наличии', 'архив');
CREATE TYPE sazonov_food.courier_status AS ENUM ('свободен', 'занят', 'на_доставке', 'уволен');
CREATE TYPE sazonov_food.order_status AS ENUM ('создан', 'готовится', 'в_доставке', 'доставлен', 'отменён');
CREATE TYPE sazonov_food.order_pay_status AS ENUM ('ожидает', 'оплачен', 'ошибка');
CREATE TYPE sazonov_food.payment_status AS ENUM ('успех', 'ошибка', 'в_обработке');
CREATE TYPE sazonov_food.payment_type AS ENUM ('карта', 'наличные', 'безнал');
CREATE TYPE sazonov_food.review_entity_type AS ENUM ('блюдо', 'ресторан', 'заказ');

CREATE TABLE sazonov_food.client (
    client_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    login varchar(80) NOT NULL UNIQUE,
    password varchar(32) NOT NULL,
    phone_number varchar(20) NOT NULL UNIQUE
);

CREATE TABLE sazonov_food.address (
    address_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    street varchar(120) NOT NULL,
    house_number varchar(20) NOT NULL,
    apartment_office varchar(20),
    CONSTRAINT address_unique UNIQUE
        (street, house_number, apartment_office)
);

CREATE UNIQUE INDEX address_without_apartment_unique
    ON sazonov_food.address (street, house_number)
    WHERE apartment_office IS NULL;

CREATE TABLE sazonov_food.client_address (
    client_id uuid REFERENCES sazonov_food.client (client_id),
    address_id uuid REFERENCES sazonov_food.address (address_id),
    PRIMARY KEY (client_id, address_id)
);

CREATE TABLE sazonov_food.restaurant (
    restaurant_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    restaurant_name varchar(150) NOT NULL,
    address_id uuid NOT NULL UNIQUE REFERENCES sazonov_food.address (address_id),
    description text NOT NULL,
    work_start time NOT NULL,
    work_end time NOT NULL,
    company_details text NOT NULL,
    rating numeric(3, 2),
    status sazonov_food.restaurant_status NOT NULL,
    CONSTRAINT restaurant_work_time CHECK (work_end > work_start),
    CONSTRAINT restaurant_rating_range CHECK (rating BETWEEN 0 AND 5)
);

CREATE TABLE sazonov_food.courier (
    courier_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    fio varchar(180) NOT NULL,
    phone_number varchar(20) NOT NULL,
    status sazonov_food.courier_status NOT NULL,
    hire_date date NOT NULL,
    dismissal_date date,
    coefficient numeric(3, 2) NOT NULL DEFAULT 0.10,
    CONSTRAINT courier_dismissal_date CHECK (
        (status <> 'уволен' OR dismissal_date IS NOT NULL)
        AND dismissal_date >= hire_date
    ),
    CONSTRAINT courier_coefficient_range CHECK (coefficient BETWEEN 0.10 AND 0.50)
);

CREATE TABLE sazonov_food.courier_pay (
    year integer,
    month integer,
    courier_id uuid REFERENCES sazonov_food.courier (courier_id),
    amount numeric(14, 2) NOT NULL,
    coefficient_used numeric(3, 2) NOT NULL,
    PRIMARY KEY (year, month, courier_id),
    CONSTRAINT courier_pay_month CHECK (month BETWEEN 1 AND 12),
    CONSTRAINT courier_pay_year CHECK (year > 0),
    CONSTRAINT courier_pay_amount CHECK (amount >= 0),
    CONSTRAINT courier_pay_coefficient CHECK (coefficient_used BETWEEN 0.10 AND 0.50)
);

CREATE TABLE sazonov_food.product_category (
    product_category_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    product_category_name varchar(100) NOT NULL
);

CREATE TABLE sazonov_food.product (
    product_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    product_name varchar(150) NOT NULL,
    product_category_id uuid NOT NULL
        REFERENCES sazonov_food.product_category (product_category_id),
    price numeric(12, 2) NOT NULL,
    restaurant_id uuid NOT NULL REFERENCES sazonov_food.restaurant (restaurant_id),
    photo_url text,
    rating numeric(3, 2),
    status sazonov_food.product_status NOT NULL,
    description text NOT NULL,
    CONSTRAINT product_price_nonnegative CHECK (price >= 0),
    CONSTRAINT product_rating_range CHECK (rating BETWEEN 0 AND 5)
);

CREATE TABLE sazonov_food."order" (
    order_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    courier_id uuid NOT NULL REFERENCES sazonov_food.courier (courier_id),
    client_id uuid NOT NULL REFERENCES sazonov_food.client (client_id),
    address_id uuid NOT NULL REFERENCES sazonov_food.address (address_id),
    restaurant_id uuid NOT NULL REFERENCES sazonov_food.restaurant (restaurant_id),
    order_timestamp timestamp NOT NULL,
    delivery_timestamp timestamp,
    order_amount numeric(14, 2) NOT NULL,
    commission numeric(14, 2) NOT NULL,
    total_amount numeric(14, 2) NOT NULL,
    status sazonov_food.order_status NOT NULL,
    pay_status sazonov_food.order_pay_status NOT NULL DEFAULT 'ожидает',
    description text NOT NULL,
    CONSTRAINT order_client_address_fk FOREIGN KEY (client_id, address_id)
        REFERENCES sazonov_food.client_address (client_id, address_id),
    CONSTRAINT order_commission_ten_percent CHECK (
        commission = round(order_amount * 0.10, 2)
    ),
    CONSTRAINT order_total_formula CHECK (total_amount = order_amount + commission),
    CONSTRAINT order_total_minimum CHECK (total_amount >= 1000),
    CONSTRAINT order_delivery_time CHECK (
        status <> 'доставлен' OR delivery_timestamp IS NOT NULL
    ),
    CONSTRAINT order_delivery_not_before_creation CHECK (
        delivery_timestamp >= order_timestamp
    )
);

CREATE TABLE sazonov_food.payment (
    payment_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    order_id uuid NOT NULL REFERENCES sazonov_food."order" (order_id),
    payment_type sazonov_food.payment_type NOT NULL,
    amount numeric(14, 2) NOT NULL,
    transaction_id varchar(120) NOT NULL UNIQUE,
    transaction_timestamp timestamp NOT NULL,
    status sazonov_food.payment_status NOT NULL
);

CREATE UNIQUE INDEX payment_one_success_idx
    ON sazonov_food.payment (order_id)
    WHERE status = 'успех';

CREATE TABLE sazonov_food.order_structure (
    order_id uuid REFERENCES sazonov_food."order" (order_id),
    product_id uuid REFERENCES sazonov_food.product (product_id),
    quantity numeric(12, 3) NOT NULL,
    PRIMARY KEY (order_id, product_id),
    CONSTRAINT order_structure_quantity_positive CHECK (quantity > 0)
);

CREATE TABLE sazonov_food.review (
    review_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    client_id uuid NOT NULL REFERENCES sazonov_food.client (client_id),
    review_timestamp timestamp NOT NULL,
    entity_id uuid NOT NULL,
    entity_type sazonov_food.review_entity_type NOT NULL,
    order_id uuid NOT NULL REFERENCES sazonov_food."order" (order_id),
    description text NOT NULL,
    photo_url text,
    rating numeric NOT NULL,
    CONSTRAINT review_rating_range CHECK (rating BETWEEN 1 AND 5),
    CONSTRAINT review_unique_target UNIQUE (order_id, entity_type, entity_id)
);
