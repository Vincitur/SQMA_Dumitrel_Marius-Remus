package SQM_HW;
// Marius-Remus Dumitrel

import static org.junit.Assert.*;
import java.util.List;
import org.junit.Before;
import org.junit.Test;

public class AdvancedOperationsTest {
    Matematica mate;

    @Before
    public void setUp() {
        mate = new Matematica();
    }

    @Test
    public void testSum() {
        assertEquals(10, mate.sum(List.of(1, 2, 3, 4)));
    }

    @Test
    public void testIsEven() {
        assertTrue(mate.isEven(2));
        assertFalse(mate.isEven(3));
    }

    @Test
    public void testIsPrime() {
        assertTrue(mate.isPrime(5));
        assertFalse(mate.isPrime(4));
    }

    @Test
    public void testFindPrimes() {
        assertEquals(List.of(2, 3, 5, 7, 11), mate.findPrimes(11));
    }
}
