import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;

public class SeedDatabase {
    private static final int MAX_CONNECTION_ATTEMPTS = 40;
    private static final long RETRY_DELAY_MILLIS = 15_000;

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            throw new IllegalArgumentException("Usage: SeedDatabase <seed.sql>");
        }

        String host = requiredEnvironment("DB_HOST");
        String port = requiredEnvironment("DB_PORT");
        String user = requiredEnvironment("DB_USER");
        String password = requiredEnvironment("DB_PASSWORD");
        String masterUrl = connectionUrl(host, port, "master");

        try (Connection connection = connectWithRetry(masterUrl, user, password)) {
            String sql = Files.readString(Path.of(args[0]));
            for (String batch : sql.split("(?im)^[\\t ]*GO[\\t ]*(?:--.*)?$")) {
                if (!batch.isBlank()) {
                    try (Statement statement = connection.createStatement()) {
                        statement.execute(batch);
                    }
                }
            }
        }

        try (Connection connection = DriverManager.getConnection(
                    connectionUrl(host, port, "demo"), user, password);
             Statement statement = connection.createStatement();
             ResultSet rows = statement.executeQuery(
                    "SELECT (SELECT COUNT(*) FROM dbo.customers), "
                            + "(SELECT COUNT(*) FROM dbo.orders)")) {
            rows.next();
            System.out.printf("Database seed succeeded: customers=%d, orders=%d%n",
                    rows.getInt(1), rows.getInt(2));
        }
    }

    private static Connection connectWithRetry(String url, String user, String password)
            throws InterruptedException, SQLException {
        SQLException lastFailure = null;

        for (int attempt = 1; attempt <= MAX_CONNECTION_ATTEMPTS; attempt++) {
            try {
                return DriverManager.getConnection(url, user, password);
            } catch (SQLException exception) {
                lastFailure = exception;
                if (attempt == MAX_CONNECTION_ATTEMPTS) {
                    break;
                }

                System.out.printf("Waiting for RDS SQL Server (attempt %d/%d)...%n",
                        attempt, MAX_CONNECTION_ATTEMPTS);
                Thread.sleep(RETRY_DELAY_MILLIS);
            }
        }

        throw lastFailure;
    }

    private static String connectionUrl(String host, String port, String database) {
        return "jdbc:sqlserver://" + host + ":" + port
                + ";databaseName=" + database
                + ";encrypt=true;trustServerCertificate=true;loginTimeout=30";
    }

    private static String requiredEnvironment(String name) {
        String value = System.getenv(name);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException(name + " is not set");
        }
        return value;
    }
}
