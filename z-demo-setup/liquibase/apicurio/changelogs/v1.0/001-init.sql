--liquibase formatted sql

--changeset apicurio:1 dbms:postgresql
--comment: Apicurio Registry initial schema tracking
-- Apicurio manages its own migrations internally; this serves as
-- a Liquibase baseline for future custom schema changes.
SELECT 1;
