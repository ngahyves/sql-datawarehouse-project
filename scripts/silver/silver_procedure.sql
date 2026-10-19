/*============================================================
   SILVER LAYER — FULL RELOAD PROCEDURE
   
   Purpose:
   - Load all Bronze tables into the Silver layer with
     cleansing, standardization, and business-rule fixes.
   - Truncate + reload (full refresh strategy).
   - Session-level sql_mode is disabled to allow safe type
     conversions and NULL insertions without strict-mode
     rejections (year 0000, invalid dates, etc.).
   
   Tables processed:
     CRM : crm_cust_info, crm_prd_info, crm_sales_details
     ERP : erp_cust_az12, erp_loc_a101, erp_px_cat_g1v2
   
   Notes:
   - Each Silver table is fully truncated before reload.
   - All transformations are deterministic and idempotent:
     re-running the procedure always yields the same result.
   ============================================================ */

DELIMITER $$

DROP PROCEDURE IF EXISTS silver.load_all_silver_data$$

CREATE PROCEDURE silver.load_all_silver_data()
BEGIN

    -- Disable strict mode for the duration of this session
    -- (avoids 1292 / 1265 errors when inserting legacy dates)
    SET SESSION sql_mode = '';

    -- ====================================================================
    -- PART 1 : CRM TABLES
    -- ====================================================================

    -- --------------------------------------------------------------
    -- 1.a — CRM CUSTOMER INFORMATION
    --   - Deduplicate: keep only the latest record per customer
    --     (ROW_NUMBER partitioned by cst_id, ordered by create date DESC)
    --   - Trim text fields
    --   - Decode marital status: M -> Married, S -> Single, else n/a
    --   - Decode gender: F -> Female, M -> Male, else n/a
    -- --------------------------------------------------------------
    TRUNCATE TABLE silver.crm_cust_info;

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
        -- Keep only the latest record per customer
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
        -- Data cleaning and standardization
        SELECT
            cst_id,
            TRIM(cst_key)                                                    AS cst_key,
            TRIM(cst_firstname)                                              AS cst_firstname,
            TRIM(cst_lastname)                                               AS cst_lastname,
            CASE
                WHEN UPPER(TRIM(cst_marital_status)) = 'M' THEN 'Married'
                WHEN UPPER(TRIM(cst_marital_status)) = 'S' THEN 'Single'
                ELSE 'n/a'
            END                                                              AS cst_marital_status,
            CASE
                WHEN UPPER(TRIM(cst_gndr)) = 'F' THEN 'Female'
                WHEN UPPER(TRIM(cst_gndr)) = 'M' THEN 'Male'
                ELSE 'n/a'
            END                                                              AS cst_gndr,
            cst_create_date
        FROM deduplicated
        WHERE rn = 1
    )
    SELECT 
        cst_id,
        cst_key,
        cst_firstname,
        cst_lastname,
        cst_marital_status,
        cst_gndr,
        cst_create_date
    FROM cleaned;


    -- --------------------------------------------------------------
    -- 1.b — CRM PRODUCTS INFORMATION (SCD Type 2)
    --   - Split prd_key:
    --       positions 1-5  -> cat_id  (join with erp_px_cat_g1v2)
    --       positions 7-end -> prd_key (join with sales_details)
    --   - Trim product name
    --   - Replace NULL costs with 0
    --   - Decode product line: M/R/S/T -> readable labels
    --   - Convert prd_start_dt from INT YYYYMMDD to DATE (0 -> NULL)
    --   - Recalculate prd_end_dt = day before the next version's start
    --     (fixes inconsistent source end dates)
    -- --------------------------------------------------------------
    TRUNCATE TABLE silver.crm_prd_info;

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
        -- Split the product key (category part)
        REPLACE(SUBSTRING(prd_key, 1, 5), '-', '_')                          AS cat_id,
        -- Split the product key (product part)
        SUBSTRING(prd_key, 7, LENGTH(prd_key))                               AS prd_key,
        -- Normalize product name
        TRIM(prd_nm)                                                         AS prd_nm,
        -- Replace NULL costs with 0
        COALESCE(prd_cost, 0)                                                AS prd_cost,
        -- Decode product line abbreviations
        CASE 
            WHEN UPPER(TRIM(prd_line)) = 'M' THEN 'Mountain'
            WHEN UPPER(TRIM(prd_line)) = 'R' THEN 'Road'
            WHEN UPPER(TRIM(prd_line)) = 'S' THEN 'Other sales'
            WHEN UPPER(TRIM(prd_line)) = 'T' THEN 'Tourism'
            ELSE 'n/a'
        END                                                                  AS prd_line,
        -- Convert INT YYYYMMDD -> DATE (0 becomes NULL)
        STR_TO_DATE(
            CAST(NULLIF(prd_start_dt, 0) AS CHAR(8)), 
            '%Y%m%d'
        )                                                                    AS prd_start_dt,
        -- SCD2 end date = day before the next version's start
        CAST(
            LEAD(
                STR_TO_DATE(CAST(NULLIF(prd_start_dt, 0) AS CHAR(8)), '%Y%m%d')
            ) OVER (
                PARTITION BY prd_key 
                ORDER BY STR_TO_DATE(CAST(NULLIF(prd_start_dt, 0) AS CHAR(8)), '%Y%m%d')
            ) - INTERVAL 1 DAY
        AS DATE)                                                             AS prd_end_dt
    FROM bronze.crm_prd_info;


    -- --------------------------------------------------------------
    -- 1.c — CRM SALES DETAILS
    --   - Convert INT dates (YYYYMMDD) to DATE:
    --       * 0 or NULL or non-8-digit -> NULL
    --       * REGEXP guards against structurally invalid dates
    --         (year 0000, month 13, day 32, etc.)
    --   - Fix quantities  : use ABS() to remove negatives
    --   - Fix sales       : recompute = qty_clean × |price|
    --                       when original is invalid or inconsistent
    --   - Fix prices      : recompute = sales_clean ÷ qty_clean
    --                       when original is NULL or <= 0
    --   - CTEs used to chain fixes (MySQL aliases can't be
    --     referenced within the same SELECT)
    -- --------------------------------------------------------------
    TRUNCATE TABLE silver.crm_sales_details;

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
        -- Step 1: INT YYYYMMDD -> DATE, with full validation
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
                  OR CAST(sls_order_dt AS CHAR(8)) NOT REGEXP '^(19|20)[0-9]{6}$'
                THEN NULL
                ELSE STR_TO_DATE(CAST(sls_order_dt AS CHAR(8)), '%Y%m%d')
            END AS sls_order_dt,
            CASE 
                WHEN sls_ship_dt IS NULL 
                  OR sls_ship_dt = 0 
                  OR CAST(sls_ship_dt AS CHAR(8)) NOT REGEXP '^(19|20)[0-9]{6}$'
                THEN NULL
                ELSE STR_TO_DATE(CAST(sls_ship_dt AS CHAR(8)), '%Y%m%d')
            END AS sls_ship_dt,
            CASE 
                WHEN sls_due_dt IS NULL 
                  OR sls_due_dt = 0 
                  OR CAST(sls_due_dt AS CHAR(8)) NOT REGEXP '^(19|20)[0-9]{6}$'
                THEN NULL
                ELSE STR_TO_DATE(CAST(sls_due_dt AS CHAR(8)), '%Y%m%d')
            END AS sls_due_dt
        FROM bronze.crm_sales_details
    ),
    quantity_fixed AS (
        -- Step 2: force quantity to be positive
        SELECT 
            *,
            ABS(sls_quantity) AS qty_clean
        FROM dates_cleaned
    ),
    sales_fixed AS (
        -- Step 3: recompute sales when invalid or inconsistent
        SELECT 
            *,
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
        -- Step 4: recompute price when invalid
        SELECT 
            *,
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
        sales_clean   AS sls_sales,
        qty_clean     AS sls_quantity,
        price_clean   AS sls_price
    FROM price_fixed;


    -- ====================================================================
    -- PART 2 : ERP TABLES
    -- ====================================================================

    -- --------------------------------------------------------------
    -- 2.a — ERP CUSTOMER INFORMATION (extra)
    --   - Strip 'NAS' prefix from cid (business rule: match with CRM key)
    --   - Validate birth date: reject before 1900 or in the future
    --   - Standardize gender to Male / Female / n/a
    --     (accepts M/MALE/HOMME and F/FEMALE/FEMME variants)
    -- --------------------------------------------------------------
    TRUNCATE TABLE silver.erp_cust_az12;

    INSERT INTO silver.erp_cust_az12 (
        cid,
        bdate,
        gen
    )
    SELECT 
        TRIM(
            CASE 
                WHEN cid LIKE 'NAS%' THEN SUBSTRING(cid, 4, LENGTH(cid)) 
                ELSE cid 
            END
        )                                                                    AS cid,
        CASE 
            WHEN bdate IS NULL 
              OR bdate < '1900-01-01' 
              OR bdate > CURDATE() 
            THEN NULL 
            ELSE bdate 
        END                                                                  AS bdate,
        CASE 
            WHEN UPPER(TRIM(gen)) IN ('M', 'MALE', 'HOMME')      THEN 'Male'
            WHEN UPPER(TRIM(gen)) IN ('F', 'FEMALE', 'FEMME')    THEN 'Female'
            ELSE 'n/a'
        END                                                                  AS gen
    FROM bronze.erp_cust_az12;


    -- --------------------------------------------------------------
    -- 2.b — ERP CUSTOMER LOCATION
    --   - Remove '-' from cid (matches CRM customer key format)
    --   - Standardize country names
    --   - Replace NULL / empty country with 'n/a'
    -- --------------------------------------------------------------
    TRUNCATE TABLE silver.erp_loc_a101;

    INSERT INTO silver.erp_loc_a101 (
        cid,
        cntry
    )
    SELECT 
        TRIM(REPLACE(cid, '-', ''))                                          AS cid,
        CASE 
            WHEN TRIM(cntry) = 'DE'                              THEN 'Germany'
            WHEN TRIM(cntry) IN ('US', 'USA', 'United States')   THEN 'United States'
            WHEN TRIM(cntry) = '' OR cntry IS NULL               THEN 'n/a'
            ELSE TRIM(cntry)
        END                                                                  AS cntry
    FROM bronze.erp_loc_a101;


    -- --------------------------------------------------------------
    -- 2.c — ERP PRODUCT CATEGORIES
    --   - Direct copy (already clean in Bronze)
    -- --------------------------------------------------------------
    TRUNCATE TABLE silver.erp_px_cat_g1v2;

    INSERT INTO silver.erp_px_cat_g1v2 (
        id,
        cat,
        subcat,
        maintenance
    )
    SELECT 
        id,
        cat,
        subcat,
        maintenance
    FROM bronze.erp_px_cat_g1v2;

END$$

DELIMITER ;
