/* 
Importing data in our Bronze layer
The scope of this layer is to have our raw tables informations for traceability and debugging
NB: It is important before creating tables to have an idea of the data model and catalog
*/
-- ==========================================================
-- 1-Creating the different empty tables of our bronze layer
-- Our data are coming from local Customer Resource Management (CRM) source and local Enterprise Resource Management (ERP) source
-- It is important to follow good practices creating table names <source_system_entiy_table>
-- e.g: -- bronze layer/crm_source/customer_info
-- ==========================================================

USE bronze;
SELECT DATABASE(); -- just to verify

-- Creating the customer's info table from Customer Resource Management
DROP TABLE IF EXISTS bronze.crm_cust_info;
CREATE TABLE bronze.crm_cust_info(
cst_id INT,
cst_key VARCHAR(50),
cst_firstname VARCHAR(50),
cst_lastname VARCHAR(50),
cst_marital_status VARCHAR(50),
cst_gndr VARCHAR(50),
cst_create_date DATE
);


-- Creating the product's info table from CRM source
DROP TABLE IF EXISTS bronze.crm_prd_info;
CREATE TABLE bronze.crm_prd_info (
    prd_id       INT,
    prd_key      VARCHAR(50),
    prd_nm       VARCHAR(50),
    prd_cost     INT,
    prd_line     VARCHAR(50),
    prd_start_dt DATETIME,
    prd_end_dt   DATETIME
);

-- Creating the main sale's details table from CRM source
DROP TABLE IF EXISTS bronze.crm_sales_details;
CREATE TABLE bronze.crm_sales_details (
    sls_ord_num  VARCHAR(50),
    sls_prd_key  VARCHAR(50),
    sls_cust_id  INT,
    sls_order_dt INT,
    sls_ship_dt  INT,
    sls_due_dt   INT,
    sls_sales    INT,
    sls_quantity INT,
    sls_price    INT
);

-- Creating the location's table for product from Enterprise Resource Management
DROP TABLE IF EXISTS bronze.erp_loc_a101;
CREATE TABLE bronze.erp_loc_a101 (
    cid    VARCHAR(50),
    cntry  VARCHAR(50)
);

-- Creating customers personal information table from erp source
DROP TABLE IF EXISTS bronze.erp_cust_az12;
CREATE TABLE bronze.erp_cust_az12 (
    cid    VARCHAR(50),
    bdate  DATE,
    gen    VARCHAR(50)
);

-- Creating a table  for products category from erp source
DROP TABLE IF EXISTS bronze.erp_px_cat_g1v2;
CREATE TABLE bronze.erp_px_cat_g1v2 (
    id           VARCHAR(50),
    cat          VARCHAR(50),
    subcat       VARCHAR(50),
    maintenance  VARCHAR(50)
);

/*
--2- Loading data
-- We will use the bulk insert method which consist of loading a massive amount of data very quickly from files directly into the data base
-- Update this path according to your environment
*/

DELIMITER $$

DROP PROCEDURE IF EXISTS load_bronze $$

CREATE PROCEDURE load_bronze()
BEGIN

    -- CRM Customers
    TRUNCATE TABLE bronze.crm_cust_info;

    LOAD DATA LOCAL INFILE '/path/to/cust_info.csv'
    INTO TABLE bronze.crm_cust_info
    FIELDS TERMINATED BY ','
    IGNORE 1 ROWS;

    -- ERP Product Categories
    TRUNCATE TABLE bronze.erp_px_cat_g1v2;

    LOAD DATA LOCAL INFILE '/path/to/PX_CAT_G1V2.csv'
    INTO TABLE bronze.erp_px_cat_g1v2
    FIELDS TERMINATED BY ','
    IGNORE 1 ROWS;

    -- ERP Locations
    TRUNCATE TABLE bronze.erp_loc_a101;

    LOAD DATA LOCAL INFILE '/path/to/LOC_A101.csv'
    INTO TABLE bronze.erp_loc_a101
    FIELDS TERMINATED BY ','
    IGNORE 1 ROWS;

    -- ERP Customers
    TRUNCATE TABLE bronze.erp_cust_az12;

    LOAD DATA LOCAL INFILE '/path/to/CUST_AZ12.csv'
    INTO TABLE bronze.erp_cust_az12
    FIELDS TERMINATED BY ','
    IGNORE 1 ROWS;

    -- CRM Products
    TRUNCATE TABLE bronze.crm_prd_info;

    LOAD DATA LOCAL INFILE '/path/to/prd_info.csv'
    INTO TABLE bronze.crm_prd_info
    FIELDS TERMINATED BY ','
    IGNORE 1 ROWS;

    -- CRM Sales
    TRUNCATE TABLE bronze.crm_sales_details;

    LOAD DATA LOCAL INFILE '/path/to/sales_details.csv'
    INTO TABLE bronze.crm_sales_details
    FIELDS TERMINATED BY ','
    IGNORE 1 ROWS;

END $$

DELIMITER ;






