--liquibase formatted sql

--changeset openproject:1 dbms:postgresql
--comment: OpenProject initial schema tracking
-- This changelog tracks the initial state of the OpenProject database.
-- OpenProject manages its own migrations internally; this serves as
-- a Liquibase baseline for future custom schema changes.
SELECT 1;
