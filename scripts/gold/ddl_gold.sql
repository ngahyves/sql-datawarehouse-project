/* Building gold layer with a customer dimension
--1-Join silver.crm_cust_info with silver.erp_cust_az12 on c_id and silver.erp_loc_a101 on c_id
-- a-After joining tables we checked if duplicates were introduced
-- b- Verified data mactching about gender
-- c- Renamed different columns
-- d-Create a surrogate key
-- Create a view to save the script and easily rebuild the table
*/
USE gold;
DROP VIEW IF EXISTS gold.dim_customers;
CREATE VIEW gold.dim_customers AS
SELECT
	ROW_NUMBER() OVER(ORDER BY cst_id) AS customer_key, -- surrogate key
	ci.cst_id AS customer_id,
    ci.cst_key AS customer_number,
    ci.cst_firstname AS first_name,
    ci.cst_lastname AS last_name,
    ci.cst_marital_status AS marital_status,
    CASE WHEN ci.cst_gndr != 'n/a' THEN ci.cst_gndr
		ELSE COALESCE(ca.gen, 'n/a')
        END AS gender,
    ci.cst_create_date AS create_date,
    ca.bdate AS birth_date,
    la.cntry AS country
FROM silver.crm_cust_info ci
LEFT JOIN silver.erp_cust_az12 ca
ON ci.cst_key= ca.cid
LEFT JOIN silver.erp_loc_a101 la
ON ci.cst_key= la.cid;

-- Verification
SELECT *
FROM gold.dim_customers;

/* Building gold layer with product dimension
--2-Join silver.crm_prd_info with silver.erp_px_cat_g1v2 on cat_id created during silver's transformations 
-- a-After joining tables we checked if duplicates were introduced
-- b- Verified data mactching about gender
-- c- Renamed different columns
-- d-Create a surrogate key
-- Create a view to save the script and easily rebuild the table
*/
USE gold;
DROP VIEW IF EXISTS gold.dim_products;
CREATE VIEW gold.dim_products AS
SELECT
	ROW_NUMBER() OVER(ORDER BY pn.prd_start_dt) AS product_key,
	pn.prd_id AS product_id,
    pn.cat_id AS category_id,
    pn.prd_key AS product_number,
    pn.prd_nm AS product_name,
    pn.prd_cost AS cost,
    pn.prd_line AS product_line,
    pn.prd_start_dt AS start_date,
    pc.cat AS category,
    pc.subcat AS sub_category,
    pc.maintenance 
FROM silver.crm_prd_info pn
LEFT JOIN silver.erp_px_cat_g1v2 pc
ON pn.cat_id= pc.id
WHERE pn.prd_end_dt IS NULL;-- Filter out current data

-- Verification
SELECT * from gold.dim_products

/* Building gold layer with sales tables details to have the fact table
--3-Join silver.sales_details fact table with the view gold.dim_products and the view gold.dim_customers
-- a-After joining tables we checked if duplicates were introduced
-- b- Verified data mactching about
-- c- Renamed different columns
-- d-This table will be at the center of our star schema
-- Create a view to save the script and easily rebuild the table
*/
DROP VIEW IF EXISTS gold.fact_sales;
CREATE VIEW gold.fact_sales AS
SELECT 
	sd.sls_ord_num AS order_number,
    sd.sls_order_dt AS order_date,
    sd.sls_ship_dt AS ship_date,
    sd.sls_due_dt AS due_date,
    sd.sls_sales AS sales,
    sd.sls_quantity AS quantity,
    sd.sls_price AS price,
    pr.product_key,
    cu.customer_id AS customer_id
FROM silver.crm_sales_details sd
LEFT JOIN gold.dim_products pr
ON sd.sls_prd_key= pr.product_number
LEFT JOIN gold.dim_customers cu
ON sd.sls_cust_id= cu.customer_id
;
-- Verification
SELECT *
FROM gold.fact_sales;





