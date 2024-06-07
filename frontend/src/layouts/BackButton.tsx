import IconButton from '@mui/material/Button';
import { useNavigate } from 'react-router';
import { IoIosArrowBack } from "react-icons/io";

const BackButton = (props: any) => {
  const navigate = useNavigate();

  const handleClick = () => {
    navigate(-1);
  };

  return (
    <IconButton
      {...props}
      startIcon={< IoIosArrowBack />}
      onClick={handleClick}
    />
  );
}

export default BackButton;