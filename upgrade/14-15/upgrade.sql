------------------------------------------------------------------------------
-- Mise � jour de la base vers la version 1.5
--
-- M�thode :
--	- psql dns < upgrade.sql
--		(attention : la mise � jour est lente)
--
-- $Id$
------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- ajout des profils dans les intervalles DHCP
------------------------------------------------------------------------------

ALTER TABLE dhcprange
	ADD COLUMN iddhcpprofil INT ;

ALTER TABLE dhcprange
	ADD CONSTRAINT iddhcpprofilfk
	FOREIGN KEY (iddhcpprofil) REFERENCES dhcpprofil(iddhcpprofil) ;

------------------------------------------------------------------------------
-- ajout du champ "droitsmtp" dans la table groupe
------------------------------------------------------------------------------

ALTER TABLE groupe
	ADD COLUMN droitsmtp INT ;

ALTER TABLE groupe
	ALTER COLUMN droitsmtp
	SET DEFAULT 0 ;

UPDATE groupe
	SET droitsmtp = 0
	WHERE droitsmtp IS NULL ;

------------------------------------------------------------------------------
-- ajout du champ "droitsmtp" dans la table RR
------------------------------------------------------------------------------

ALTER TABLE rr
	ADD COLUMN droitsmtp INT ;

ALTER TABLE rr
	ALTER COLUMN droitsmtp
	SET DEFAULT 0 ;

UPDATE rr
	SET droitsmtp = 0
	WHERE droitsmtp IS NULL ;

------------------------------------------------------------------------------
-- ajout du champ "ttl" dans la table RR
------------------------------------------------------------------------------

ALTER TABLE rr
	ADD COLUMN ttl INT ;

------------------------------------------------------------------------------
-- ajout d'un trigger sur la table DHCPPROFIL
------------------------------------------------------------------------------

CREATE TRIGGER tr_modifier_dhcpprofil
    AFTER UPDATE
    ON dhcpprofil
    FOR EACH ROW
    EXECUTE PROCEDURE generer_dhcp ()
    ;


------------------------------------------------------------------------------
-- divers
------------------------------------------------------------------------------

ALTER TABLE groupe
	ALTER COLUMN admin
	SET DEFAULT 0 ;
