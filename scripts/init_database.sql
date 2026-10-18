/* 
==========================================================
1-Creating our different data bases for our ETL process:
==========================================================
Since Mysql doest not differenciate databases and schemas. Remember that we will have 3 schemas instead of One database and 3 schemas.
This script supposes the creation of databases after verifying if they exist because it is very important.
NB: Creating these databases will delete anyone if they already exist in your environment.
*/

CREATE DATABASE IF NOT EXISTS BRONZE;
CREATE DATABASE IF NOT EXISTS SILVER;
CREATE DATABASE IF NOT EXISTS GOLD;

SHOW DATABASES;
