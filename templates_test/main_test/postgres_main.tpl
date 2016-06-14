type PostgresCfg struct {
	User   string `toml:"user"`
	Pass   string `toml:"pass"`
	Host   string `toml:"host"`
	Port   int    `toml:"port"`
	DBName string `toml:"dbname"`
}

type Config struct {
	Postgres PostgresCfg `toml:"postgres"`
}

var cfg *Config
var testCfg *Config

var dbConn *sql.DB

func TestMain(m *testing.M) {
	// Set the DebugMode to true so we can see generated sql statements
	boil.DebugMode = true

	rand.Seed(time.Now().UnixNano())
	var err error

  err = setup()
	if err != nil {
		fmt.Printf("Unable to execute setup: %s", err)
		os.Exit(-1)
	}

	err = disableTriggers()
	if err != nil {
		fmt.Printf("Unable to disable triggers: %s", err)
	}
	boil.SetDB(dbConn)
  code := m.Run()

	err = teardown()
	if err != nil {
		fmt.Printf("Unable to execute teardown: %s", err)
		os.Exit(-1)
	}

  os.Exit(code)
}

// disableTriggers is used to disable foreign key constraints for every table.
// If this is not used we cannot test inserts due to foreign key constraint errors.
func disableTriggers() error {
	var stmts []string

	{{range .Tables}}
	stmts = append(stmts, `ALTER TABLE {{.Name}} DISABLE TRIGGER ALL;`)
	{{- end}}

	if len(stmts) == 0 {
		return nil
	}

	var err error
	for _, s := range stmts {
		_, err = dbConn.Exec(s)
		if err != nil {
			return err
		}
	}

	return nil
}

// teardown executes cleanup tasks when the tests finish running
func teardown() error {
	err := dropTestDB()
	return err
}

// dropTestDB switches its connection to the template1 database temporarily
// so that it can drop the test database without causing "in use" conflicts.
// The template1 database should be present on all default postgres installations.
func dropTestDB() error {
	var err error
	if dbConn != nil {
		if err = dbConn.Close(); err != nil {
			return err
		}
	}

	dbConn, err = DBConnect(testCfg.Postgres.User, testCfg.Postgres.Pass, "template1", testCfg.Postgres.Host, testCfg.Postgres.Port)
	if err != nil {
		return err
	}

	_, err = dbConn.Exec(fmt.Sprintf(`DROP DATABASE IF EXISTS %s;`, testCfg.Postgres.DBName))
	if err != nil {
		return err
	}

	return dbConn.Close()
}

// DBConnect connects to a database and returns the handle.
func DBConnect(user, pass, dbname, host string, port int) (*sql.DB, error) {
	connStr := fmt.Sprintf("user=%s password=%s dbname=%s host=%s port=%d",
		user, pass, dbname, host, port)

		return sql.Open("postgres", connStr)
}

func LoadConfigFile(filename string) error {
	_, err := toml.DecodeFile(filename, &cfg)

	if os.IsNotExist(err) {
		return fmt.Errorf("Failed to find the toml configuration file %s: %s", filename, err)
	}

	if err != nil {
		return fmt.Errorf("Failed to decode toml configuration file: %s", err)
	}

	return nil
}

// setup dumps the database schema and imports it into a temporary randomly
// generated test database so that tests can be run against it using the
// generated sqlboiler ORM package.
func setup() error {
	// Load the config file in the parent directory.
  err := LoadConfigFile("../sqlboiler.toml")
	if err != nil {
		return fmt.Errorf("Unable to load config file: %s", err)
	}

	testDBName := getDBNameHash(cfg.Postgres.DBName)

	// Create a randomized test configuration object.
	testCfg = &Config{}
	testCfg.Postgres.Host = cfg.Postgres.Host
	testCfg.Postgres.Port = cfg.Postgres.Port
	testCfg.Postgres.User = cfg.Postgres.User
	testCfg.Postgres.Pass = cfg.Postgres.Pass
	testCfg.Postgres.DBName = testDBName

	err = dropTestDB()
	if err != nil {
		fmt.Printf("%#v\n", err)
		return err
	}

	fhSchema, err := ioutil.TempFile(os.TempDir(), "sqlboilerschema")
	if err != nil {
		return fmt.Errorf("Unable to create sqlboiler schema tmp file: %s", err)
	}
	defer os.Remove(fhSchema.Name())

	passDir, err := ioutil.TempDir(os.TempDir(), "sqlboiler")
	if err != nil {
		return fmt.Errorf("Unable to create sqlboiler tmp dir for postgres pw file: %s", err)
	}
	defer os.RemoveAll(passDir)

	// Write the postgres user password to a tmp file for pg_dump
	pwBytes := []byte(fmt.Sprintf("%s:%d:%s:%s:%s",
		cfg.Postgres.Host,
		cfg.Postgres.Port,
		cfg.Postgres.DBName,
		cfg.Postgres.User,
		cfg.Postgres.Pass,
	))

	passFilePath := passDir + "/pwfile"

	err = ioutil.WriteFile(passFilePath, pwBytes, 0600)
	if err != nil {
		return fmt.Errorf("Unable to create pwfile in passDir: %s", err)
	}

	// The params for the pg_dump command to dump the database schema
	params := []string{
		fmt.Sprintf(`--host=%s`, cfg.Postgres.Host),
		fmt.Sprintf(`--port=%d`, cfg.Postgres.Port),
		fmt.Sprintf(`--username=%s`, cfg.Postgres.User),
		"--schema-only",
		cfg.Postgres.DBName,
	}

	// Dump the database schema into the sqlboilerschema tmp file
	errBuf := bytes.Buffer{}
	cmd := exec.Command("pg_dump", params...)
	cmd.Stderr = &errBuf
	cmd.Stdout = fhSchema
	cmd.Env = append(os.Environ(), fmt.Sprintf(`PGPASSFILE=%s`, passFilePath))

	if err := cmd.Run(); err != nil {
		fmt.Printf("pg_dump exec failed: %s\n\n%s\n", err, errBuf.String())
	}

	dbConn, err = DBConnect(cfg.Postgres.User, cfg.Postgres.Pass, cfg.Postgres.DBName, cfg.Postgres.Host, cfg.Postgres.Port)
	if err != nil {
		return err
	}

	// Create the randomly generated database
	_, err = dbConn.Exec(fmt.Sprintf(`CREATE DATABASE %s WITH ENCODING 'UTF8'`, testCfg.Postgres.DBName))
	if err != nil {
		return err
	}

	// Close the old connection so we can reconnect to the test database
	if err = dbConn.Close(); err != nil {
		return err
	}

	// Connect to the generated test db
	dbConn, err = DBConnect(testCfg.Postgres.User, testCfg.Postgres.Pass, testCfg.Postgres.DBName, testCfg.Postgres.Host, testCfg.Postgres.Port)
	if err != nil {
		return err
	}

	// Write the test config credentials to a tmp file for pg_dump
	testPwBytes := []byte(fmt.Sprintf("%s:%d:%s:%s:%s",
		testCfg.Postgres.Host,
		testCfg.Postgres.Port,
		testCfg.Postgres.DBName,
		testCfg.Postgres.User,
		testCfg.Postgres.Pass,
	))

	testPassFilePath := passDir + "/testpwfile"

	err = ioutil.WriteFile(testPassFilePath, testPwBytes, 0600)
	if err != nil {
		return fmt.Errorf("Unable to create testpwfile in passDir: %s", err)
	}

	// The params for the psql schema import command
	params = []string{
		fmt.Sprintf(`--dbname=%s`, testCfg.Postgres.DBName),
		fmt.Sprintf(`--host=%s`, testCfg.Postgres.Host),
		fmt.Sprintf(`--port=%d`, testCfg.Postgres.Port),
		fmt.Sprintf(`--username=%s`, testCfg.Postgres.User),
		fmt.Sprintf(`--file=%s`, fhSchema.Name()),
	}

	// Import the database schema into the generated database.
	// It is now ready to be used by the generated ORM package for testing.
	outBuf := bytes.Buffer{}
	cmd = exec.Command("psql", params...)
	cmd.Stderr = &errBuf
	cmd.Stdout = &outBuf
	cmd.Env = append(os.Environ(), fmt.Sprintf(`PGPASSFILE=%s`, testPassFilePath))

	if err = cmd.Run(); err != nil {
		fmt.Printf("psql schema import exec failed: %s\n\n%s\n", err, errBuf.String())
	}

	return nil
}
