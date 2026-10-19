/* ============================================================
   a-SILVER LAYER - Extra customers info

   Purpose:
   - Standardize customer IDs
   - Validate birth dates
   - Standardize gender values
   Source : bronze.erp_cust_az12
   Target : silver.erp_cust_az12
   ============================================================ */
TRUNCATE TABLE silver.erp_cust_az12;

INSERT INTO silver.erp_cust_az12 (
    cid,
    bdate,
    gen
)
SELECT 
    -- 1. Cleaning the key cid (removing 'NAS' if ^present)
    TRIM(CASE WHEN cid LIKE 'NAS%' THEN SUBSTRING(cid, 4, LENGTH(cid))
            ELSE cid
        END) AS cid,
    
    -- 2. Securing the birth date
    CASE 
        WHEN bdate IS NULL OR bdate < '1900-01-01' 
          OR bdate > CURDATE() 
        THEN NULL
        ELSE bdate
    END AS bdate,
    -- 3. Standardizing the gender column
    CASE 
        WHEN UPPER(TRIM(gen)) IN ('M', 'MALE', 'HOMME') THEN 'Male'
        WHEN UPPER(TRIM(gen)) IN ('F', 'FEMALE', 'FEMME') THEN 'Female'
        ELSE 'n/A'
    END AS gen
FROM bronze.erp_cust_az12;


/* ============================================================
   a-SILVER LAYER - Extra customers info location

   Purpose:
   - Standardize cid
   - Fix countries mismatching
   Source : bronze.erp_loc_a101
   Target : silver.erp_cust_a101
   ============================================================ */
TRUNCATE TABLE silver.erp_loc_a101;
INSERT INTO silver.erp_loc_a101(
    cid,
    cntry
)
SELECT 
	TRIM(REPLACE(cid, '-', '')),
    CASE WHEN TRIM(cntry) = 'DE' THEN 'Germany'
		 WHEN TRIM(cntry) IN ('US', 'USA', 'United States') THEN 'United States'
         WHEN TRIM(cntry) ='' OR cntry IS NULL THEN 'n/a'
         ELSE TRIM(cntry)
         END AS cntry
 FROM bronze.erp_loc_a101;
 SELECT DISTINCT cntry
 FROM silver.erp_loc_a101;

* ============================================================
   c-SILVER LAYER - product categories and sub categories

   Purpose:
   - Verify if it will be ready to connect with crm_product_info table
   Source : bronze.erp_px_cat_g1v2
   Target : silver.erp_px_cat_g1v2
   ============================================================ */
TRUNCATE TABLE silver.erp_px_cat_g1v2;
INSERT INTO silver.erp_px_cat_g1v2(
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
