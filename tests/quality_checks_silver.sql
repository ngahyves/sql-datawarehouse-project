/* ============================================================
   SILVER LAYER - CRM CUSTOMER INFORMATION

   Purpose:
   - Remove records with NULL customer IDs
   - Keep only the most recent record per customer
   - Remove leading and trailing spaces
   - Standardize gender values
   - Standardize marital status values

   Source : bronze.crm_cust_info
   Target : silver.crm_cust_info
   ============================================================ */
-- Refresh Silver table
TRUNCATE TABLE silver.crm_cust_info;
-- Load cleansed data from Bronze into Silver
INSERT INTO silver.crm_cust_info (
    cst_id,
    cst_key,
    cst_firstname,
    cst_lastname,
    cst_marital_status,
    cst_gndr,
    cst_create_date
)
WITH deduplicated AS (

    /* Keep only the latest record for each customer */
    SELECT
        *,
        ROW_NUMBER() OVER (
            PARTITION BY cst_id
            ORDER BY cst_create_date DESC
        ) AS rn
    FROM bronze.crm_cust_info
    WHERE cst_id IS NOT NULL

),

cleaned AS (

    /* Data cleaning and standardization */
    SELECT

        cst_id,

        TRIM(cst_key) AS cst_key,

        TRIM(cst_firstname) AS cst_firstname,

        TRIM(cst_lastname) AS cst_lastname,

        CASE
            WHEN UPPER(TRIM(cst_marital_status)) = 'M'
                THEN 'Married'
            WHEN UPPER(TRIM(cst_marital_status)) = 'S'
                THEN 'Single'
            ELSE 'n/a'
        END AS cst_marital_status,

        CASE
            WHEN UPPER(TRIM(cst_gndr)) = 'F'
                THEN 'Female'
            WHEN UPPER(TRIM(cst_gndr)) = 'M'
                THEN 'Male'
            ELSE 'n/a'
        END AS cst_gndr,
        cst_create_date
        
    FROM deduplicated
    WHERE rn = 1
)
SELECT *
FROM cleaned;

/*============================================================
   b- CRM products informations
   Purpose:
   - Split prd_key into cat_id + clean prd_key (for joins)
   - Decode prd_line abbreviations into readable labels
   - Replace NULL costs with 0
   - Convert INT YYYYMMDD -> DATE (0 becomes NULL)
   - Recalculate prd_end_dt = day before next version's start
     (fixes source end dates that were sometimes before start)
   ============================================================ */

-- 0. Prepare the silver table
--    Add cat_id and convert dates into DATE
ALTER TABLE silver.crm_prd_info 
ADD COLUMN cat_id VARCHAR(50) AFTER prd_id;

ALTER TABLE silver.crm_prd_info 
    MODIFY COLUMN prd_start_dt DATE NULL,
    MODIFY COLUMN prd_end_dt   DATE NULL;

-- 1. Resfresh table
TRUNCATE TABLE silver.crm_prd_info;

-- 2. Load bronze table
INSERT INTO silver.crm_prd_info (
    prd_id,
    cat_id,
    prd_key,
    prd_nm,
    prd_cost,
    prd_line,
    prd_start_dt,
    prd_end_dt
)
SELECT 
    prd_id,
    -- Split the product key to connect with erp_px_cat_g1v2 and sales_details
    REPLACE(SUBSTRING(prd_key, 1, 5), '-', '_') AS cat_id,
    SUBSTRING(prd_key, 7, LENGTH(prd_key)) AS prd_key,
    TRIM(prd_nm) AS prd_nm,
    COALESCE(prd_cost, 0) AS prd_cost,
    CASE 
        WHEN UPPER(TRIM(prd_line)) = 'M' THEN 'Mountain'
        WHEN UPPER(TRIM(prd_line)) = 'R' THEN 'Road'
        WHEN UPPER(TRIM(prd_line)) = 'S' THEN 'Other sales'
        WHEN UPPER(TRIM(prd_line)) = 'T' THEN 'Tourism'
        ELSE 'n/a'
    END AS prd_line,
    -- Convert INT YYYYMMDD -> DATE, 0 becomes NULL
    STR_TO_DATE(CAST(NULLIF(prd_start_dt, 0) AS CHAR), '%Y%m%d') AS prd_start_dt,
    -- End date = day before next version's start (NULL for current version)
    CAST(
        LEAD(STR_TO_DATE(CAST(NULLIF(prd_start_dt, 0) AS CHAR), '%Y%m%d')) OVER (
            PARTITION BY prd_key
            ORDER BY STR_TO_DATE(CAST(NULLIF(prd_start_dt, 0) AS CHAR), '%Y%m%d')
        ) - INTERVAL 1 DAY
    AS DATE) AS prd_end_dt
FROM bronze.crm_prd_info;

/*============================================================
   c- Sales details table
   Purpose:
   - Replace 0 / invalid INT dates with NULL
   - Convert sls_order_dt / sls_ship_dt / sls_due_dt from
     INT YYYYMMDD to DATE
   - Reject structurally invalid dates (year 0000, month 13, day 32)
     using REGEXP guard to avoid MySQL 1292 error in strict mode
   - Fix negative quantities (ABS)
   - Fix inconsistent sales (recompute = qty × |price|)
   - Fix invalid prices (recompute = sales ÷ qty)
   - Chain fixes via CTEs so each column sees the corrected
     value of the previous step (not the raw Bronze value)
   ============================================================ */

-- 0. Prepare the silver table
ALTER TABLE silver.crm_sales_details 
    MODIFY COLUMN sls_order_dt DATE NULL,
    MODIFY COLUMN sls_ship_dt  DATE NULL,
    MODIFY COLUMN sls_due_dt   DATE NULL;

-- 1. Refresh the silver table
TRUNCATE TABLE silver.crm_sales_details;

-- 2. load from bronze
INSERT INTO silver.crm_sales_details (
    sls_ord_num,
    sls_prd_key,
    sls_cust_id,
    sls_order_dt,
    sls_ship_dt,
    sls_due_dt,
    sls_sales,
    sls_quantity,
    sls_price
)
WITH dates_cleaned AS (
    SELECT 
        sls_ord_num,
        sls_prd_key,
        sls_cust_id,
        sls_sales,
        sls_quantity,
        sls_price,
        CASE 
            WHEN sls_order_dt IS NULL 
              OR sls_order_dt = 0 
              OR CAST(sls_order_dt AS CHAR) NOT REGEXP '^(19|20)[0-9]{6}$'
            THEN NULL
            ELSE STR_TO_DATE(CAST(sls_order_dt AS CHAR), '%Y%m%d')
        END AS sls_order_dt,
        CASE 
            WHEN sls_ship_dt IS NULL 
              OR sls_ship_dt = 0 
              OR CAST(sls_ship_dt AS CHAR) NOT REGEXP '^(19|20)[0-9]{6}$'
            THEN NULL
            ELSE STR_TO_DATE(CAST(sls_ship_dt AS CHAR), '%Y%m%d')
        END AS sls_ship_dt,
        CASE 
            WHEN sls_due_dt IS NULL 
              OR sls_due_dt = 0 
              OR CAST(sls_due_dt AS CHAR) NOT REGEXP '^(19|20)[0-9]{6}$'
            THEN NULL
            ELSE STR_TO_DATE(CAST(sls_due_dt AS CHAR), '%Y%m%d')
        END AS sls_due_dt
    FROM bronze.crm_sales_details
),
quantity_fixed AS (
    SELECT *, ABS(sls_quantity) AS qty_clean
    FROM dates_cleaned
),
sales_fixed AS (
    SELECT *,
        CASE 
            WHEN sls_sales IS NULL 
              OR sls_sales <= 0 
              OR sls_sales != qty_clean * ABS(sls_price)
            THEN qty_clean * ABS(sls_price)
            ELSE sls_sales
        END AS sales_clean
    FROM quantity_fixed
),
price_fixed AS (
    SELECT *,
        CASE 
            WHEN sls_price IS NULL OR sls_price <= 0 
            THEN sales_clean / NULLIF(qty_clean, 0)
            ELSE sls_price
        END AS price_clean
    FROM sales_fixed
)
SELECT 
    sls_ord_num,
    sls_prd_key,
    sls_cust_id,
    sls_order_dt,
    sls_ship_dt,
    sls_due_dt,
    sales_clean AS sls_sales,
    qty_clean   AS sls_quantity,
    price_clean AS sls_price
FROM price_fixed;
