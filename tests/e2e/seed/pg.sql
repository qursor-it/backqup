CREATE TABLE items (id serial PRIMARY KEY, name text NOT NULL);
INSERT INTO items (name) SELECT md5(g::text) FROM generate_series(1, 200) g;
