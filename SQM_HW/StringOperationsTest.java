package SQM_HW;
// Marius-Remus Dumitrel

import static org.junit.Assert.*;
import org.junit.Before;
import org.junit.Test;

public class StringOperationsTest {
    Matematica mate;

    @Before
    public void setUp() {
        mate = new Matematica();
    }

    @Test
    public void testCountChars() {
        assertEquals(5, mate.countChars("Hello"));
        assertEquals(0, mate.countChars(""));
        assertEquals(0, mate.countChars(null));
    }

    @Test
    public void testRepeatString() {
        assertEquals("HiHiHi", mate.repeatString("Hi", 3));
        assertEquals("", mate.repeatString("Hi", 0));
        assertNull(mate.repeatString(null, 5));
    }
}
