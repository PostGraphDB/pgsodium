
CREATE FUNCTION pgsodium.lookup_key_by_id(id uuid) RETURNS pgsodium.valid_key
AS $$
    SELECT * from pgsodium.valid_key vk WHERE vk.id = id;
$$
SECURITY DEFINER
LANGUAGE sql
SET search_path = '';


CREATE FUNCTION pgsodium.lookup_key_by_name(name text) RETURNS pgsodium.valid_key
AS $$
    SELECT * from pgsodium.valid_key vk WHERE vk.name = name;
$$
SECURITY DEFINER
LANGUAGE sql
SET search_path = '';


DROP FUNCTION pgsodium.create_mask_view(oid, integer, boolean);
CREATE FUNCTION pgsodium.create_mask_view(relid oid, subid integer, debug boolean = false, view_owner name = current_user)
    RETURNS void AS
  $$
DECLARE
  body text;
  source_name text;
  rule pgsodium.masking_rule;
BEGIN
  SELECT * INTO STRICT rule FROM pgsodium.masking_rule WHERE attrelid = relid and attnum = subid ;

  source_name := relid::regclass;

  body = format(
    $c$
    DROP VIEW IF EXISTS %s;
    CREATE VIEW %s AS SELECT %s
    FROM %s;
    ALTER VIEW %s OWNER TO %s;
    $c$,
    rule.view_name,
    rule.view_name,
    pgsodium.decrypted_columns(relid),
    source_name,
    rule.view_name,
    view_owner
  );
  IF debug THEN
    RAISE NOTICE '%', body;
  END IF;
  EXECUTE body;

  body = format(
    $c$
    DROP FUNCTION IF EXISTS %s.%s_encrypt_secret() CASCADE;

    CREATE OR REPLACE FUNCTION %s.%s_encrypt_secret()
      RETURNS TRIGGER
      LANGUAGE plpgsql
      AS $t$
    BEGIN
    %s;
    RETURN new;
    END;
    $t$;

    ALTER FUNCTION  %s.%s_encrypt_secret() OWNER TO %s;

    DROP TRIGGER IF EXISTS %s_encrypt_secret_trigger ON %s.%s;

    CREATE TRIGGER %s_encrypt_secret_trigger
      BEFORE INSERT ON %s
      FOR EACH ROW
      EXECUTE FUNCTION %s.%s_encrypt_secret ();
      $c$,
    rule.relnamespace,
    rule.relname,
    rule.relnamespace,
    rule.relname,
    pgsodium.encrypted_columns(relid),
    rule.relnamespace,
    rule.relname,
    view_owner,
    rule.relname,
    rule.relnamespace,
    rule.relname,
    rule.relname,
    source_name,
    rule.relnamespace,
    rule.relname
  );
  if debug THEN
    RAISE NOTICE '%', body;
  END IF;
  EXECUTE body;

  PERFORM pgsodium.mask_role(oid::regrole, source_name, rule.view_name)
  FROM pg_roles WHERE pgsodium.has_mask(oid::regrole, source_name);

  RETURN;
END
  $$
  LANGUAGE plpgsql
  VOLATILE
  SET search_path='pg_catalog'
;

DROP FUNCTION pgsodium.update_mask(oid, boolean);
CREATE FUNCTION pgsodium.update_mask(target oid, debug boolean = false, view_owner name = current_user)
RETURNS void AS
  $$
BEGIN
  ALTER EVENT TRIGGER pgsodium_trg_mask_update DISABLE;
  PERFORM pgsodium.create_mask_view(objoid, objsubid, debug, view_owner)
    FROM pg_catalog.pg_seclabel
    WHERE objoid = target
        AND label ILIKE 'ENCRYPT%'
        AND provider = 'pgsodium';
  ALTER EVENT TRIGGER pgsodium_trg_mask_update ENABLE;
  RETURN;
END
$$
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path=''
;

DROP FUNCTION pgsodium.update_masks(boolean);
CREATE FUNCTION pgsodium.update_masks(debug boolean = false, view_owner name = current_user)
RETURNS void AS
  $$
BEGIN
  PERFORM pgsodium.update_mask(objoid, debug, view_owner)
    FROM pg_catalog.pg_seclabel
    WHERE label ilike 'ENCRYPT%'
       AND provider = 'pgsodium';
  RETURN;
END
$$
  LANGUAGE plpgsql
  SET search_path=''
;

CREATE OR REPLACE FUNCTION pgsodium.crypto_aead_det_encrypt(message bytea, additional bytea, key_uuid uuid, nonce bytea)
  RETURNS bytea AS
$$
DECLARE
  key pgsodium.decrypted_key;
BEGIN
  SELECT * INTO STRICT key
    FROM pgsodium.decrypted_key v
  WHERE id = key_uuid AND key_type = 'aead-det';

  IF key.decrypted_raw_key IS NOT NULL THEN
    RETURN pgsodium.crypto_aead_det_encrypt(message, additional, key.decrypted_raw_key, nonce);
  END IF;
  RETURN pgsodium.crypto_aead_det_encrypt(message, additional, key.key_id, key.key_context, nonce);
END;
  $$
  LANGUAGE plpgsql
  SECURITY DEFINER
  STABLE
  SET search_path=''
  ;
    
CREATE OR REPLACE FUNCTION @extschema@.mask_role(masked_role regrole, source_name text, view_name text)
  RETURNS void AS
  $$
  DECLARE
  mask_schema REGNAMESPACE = '@extschema@_masks';
  source_schema REGNAMESPACE = (regexp_split_to_array(source_name, '\.'))[1];
BEGIN
  EXECUTE format(
    'GRANT SELECT ON pgsodium.key TO %s',
    masked_role);

  EXECUTE format(
    'GRANT pgsodium_keyiduser TO %s',
    masked_role);

  EXECUTE format(
    'GRANT ALL ON %s TO %s',
    view_name,
    masked_role);
  RETURN;
END
$$
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path='pg_catalog'
;

