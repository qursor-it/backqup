CREATE TABLE items (id int AUTO_INCREMENT PRIMARY KEY, name varchar(64) NOT NULL);
INSERT INTO items (name) SELECT md5(seq) FROM seq_1_to_200;
