CREATE TABLE "user"(
	id varchar(255) PRIMARY KEY,
	name TEXT,
	group_id varchar(255)
);

CREATE TABLE "user_group"(
	id varchar(255) PRIMARY KEY,
	name TEXT
);

ALTER TABLE "user" ADD CONSTRAINT fk_group_id FOREIGN KEY (group_id) REFERENCES "user_group"(id);

INSERT INTO "user_group" (id, name) VALUES('group1', 'Group 1');
INSERT INTO "user" (id, name, group_id) VALUES('user1', 'User 1', 'group1');
INSERT INTO "user" (id, name, group_id) VALUES('user2', 'User 2', 'group1');
