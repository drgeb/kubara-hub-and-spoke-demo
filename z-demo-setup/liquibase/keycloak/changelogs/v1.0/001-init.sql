--liquibase formatted sql

--changeset keycloak:1 dbms:postgresql
--comment: Keycloak initial schema tracking
-- Keycloak manages its own migrations internally; this serves as
-- a Liquibase baseline for future custom schema changes.
SELECT 1;
