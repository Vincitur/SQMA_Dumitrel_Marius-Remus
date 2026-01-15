package SQM_HW;
// Marius-Remus Dumitrel

import static org.junit.Assert.*;
import org.junit.Before;
import org.junit.Test;

public class BasicOperationsTest {
    Matematica mate;

    @Before
    public void setUp() {
        mate = new Matematica();
    }

    @Test
    public void testAdd() {
        assertEquals(5, mate.add(2, 3));
    }

    @Test
    public void testSubtract() {
        assertEquals(2, mate.subtract(3, 1));
    }

    @Test
    public void testMultiply() {
        assertEquals(10, mate.multiply(2, 5));
    }

    @Test
    public void testDivide() {
        assertEquals(6, mate.divide(18, 3));
    }
}
